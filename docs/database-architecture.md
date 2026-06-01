# pgfleet — Architecture & Design

Self-hosted PostgreSQL on an OVH VPS, serving multiple projects, with AWS Amplify
(Lambda) as the primary consumer. This document is the source of truth for the design
**decisions** (the *why*). The **implementation** is now Infrastructure-as-Code:
**Ansible** (`ansible/`, see [`ansible.md`](./ansible.md)) renders the configs shown here
as role templates; **CloudFormation** (`cloudformation/`) provisions the AWS pieces. The
inline config snippets below are illustrative — the live versions are the role templates.

## Context & constraints

> The host, provider, and AWS regions below are the **reference deployment** — all configurable.
> Any Ubuntu VPS and any AWS region work; set yours in `vars.yml` + `private/config.mk`. The
> region/location specifics (Warsaw, Frankfurt, the cross-link RTT) are just this author's setup.

| Decision              | Value                                                            |
| --------------------- | ---------------------------------------------------------------- |
| Host                  | OVH VPS — **4 vCPU / 8 GB RAM / 75 GB disk** — **os-waw2 (Warsaw)** |
| App platform          | AWS Amplify → **Lambda** — **eu-central-1 (Frankfurt)**          |
| Backups / failover    | AWS S3 + **pilot-light** on-demand EC2 — **eu-central-1**        |
| Peak load (lead app)  | ~300 concurrent users                                            |
| Multi-tenancy         | One PG cluster, **one database per project**                     |
| Backups               | **pgBackRest → AWS S3 (eu-central-1)** with WAL/PITR             |
| DR strategy           | **Pilot-light** — alert → on-demand EC2 self-restores from S3 → DNS repoint |
| Deployment            | **docker-compose** (PG+pgvector+pgBackRest image, PgBouncer, exporters) |
| DNS                   | **db.example.com** → DB; low TTL for failover repoint          |
| Network               | Frankfurt ↔ Warsaw, ~300 km → cross-link RTT **~10–15 ms**       |

The single most important design fact: **Lambda's connection model is hostile to
PostgreSQL.** Everything below follows from solving that.

---

## 1. The Lambda ↔ Postgres connection problem

PostgreSQL forks **one OS process per connection** (~5–10 MB RAM + scheduler cost each).
A 4 vCPU / 8 GB box is healthy at ~100–150 *real* backend connections — beyond that,
context-switching and memory pressure degrade everything.

Lambda is the opposite: **every concurrent execution environment opens its own
connection and holds it** until the environment is recycled. There is no sharing between
invocations. Under a 300-user spike, Amplify can hold hundreds of mostly-idle
connections — Postgres would exhaust `max_connections` and start refusing logins long
before you run out of CPU.

### Solution: PgBouncer in transaction mode (mandatory)

```
            Amplify / Lambda (100s of clients, each 1 conn)
                              │  TLS
                              ▼
                   ┌──────────────────────┐
                   │      PgBouncer       │  pool_mode = transaction
                   │  max_client_conn=2000│  (multiplexes many clients...
                   └──────────┬───────────┘   ...onto few server conns)
                              │  ~20–40 server conns
                              ▼
                   ┌──────────────────────┐
                   │     PostgreSQL 16    │  max_connections = 120
                   │  proj_a / proj_b /…  │
                   └──────────────────────┘
```

PgBouncer accepts thousands of cheap client connections and lends a real Postgres
connection **only for the duration of a transaction**, then returns it to the pool.
A handful of server connections can serve hundreds of Lambdas.

#### ⚠️ Transaction mode breaks session features — fix it in the app

Transaction pooling means a client does **not** keep the same backend across statements.
With **PgBouncer ≥ 1.21 + `max_prepared_statements > 0`** (§2), prepared statements now
work through the pool — but `SET` (session-level), advisory locks held across statements,
and `LISTEN/NOTIFY` still don't persist (use `SET LOCAL` inside a transaction instead).
Configure your data layer accordingly:

- **Prisma 7 (current, GA Nov 2025):** `directUrl` was **removed** — the migration/CLI
  direct connection is configured in `prisma.config.ts`; Prisma Client uses the pooled
  PgBouncer URL via a driver adapter. With PgBouncer ≥ 1.21, **do not** set `pgbouncer=true`.
  (Prisma 6.x: keep `?pgbouncer=true` + `directUrl`.) Details in
  [`amplify-nextjs-setup.md`](./amplify-nextjs-setup.md) §1.
- **node-postgres / pg:** fine as-is now that the pool serves prepared statements; keep the
  client-side pool tiny (1–2) since PgBouncer is the real pool.
- **Drizzle:** `postgres`/`pg` driver works; no need to force `prepare: false`.

---

## 2. PgBouncer configuration

`/etc/pgbouncer/pgbouncer.ini` (transaction mode, sized for this box):

```ini
[databases]
proj_a = host=127.0.0.1 port=5432 dbname=proj_a
proj_b = host=127.0.0.1 port=5432 dbname=proj_b

[pgbouncer]
listen_addr = 0.0.0.0
listen_port = 6432
auth_type   = scram-sha-256
auth_file   = /etc/pgbouncer/userlist.txt

pool_mode          = transaction
max_prepared_statements = 200  ; PgBouncer >= 1.21: serve prepared statements through the
                               ; transaction pool, so apps need NOT set pgbouncer=true
max_client_conn    = 2000      ; how many Lambda conns we accept
default_pool_size  = 25        ; server conns per (user,db) — the real cost
min_pool_size      = 5
reserve_pool_size  = 10        ; burst headroom
reserve_pool_timeout = 3

server_idle_timeout = 600
server_lifetime     = 3600
query_wait_timeout  = 120      ; client waits in queue rather than erroring

; TLS to clients (Lambda → PgBouncer)
client_tls_sslmode    = require
client_tls_key_file   = /etc/pgbouncer/server.key
client_tls_cert_file  = /etc/pgbouncer/server.crt
client_tls_protocols  = secure   ; TLS 1.2 / 1.3 only
```

**Sizing math:** `default_pool_size` × number of (user, db) pairs must stay well under
Postgres `max_connections`. With 25/pool and ~3 projects = ~75 server conns + reserve —
comfortably below 120. Start at 25 and tune by watching `SHOW POOLS;` for queue depth.
On 4 vCPU, real concurrency sweet spot is roughly `2–4 × cores` actively running, so a
pool of ~20–30 with the rest queueing briefly is correct, not undersized.

### Per-project pool sizing ("cooks per app")
Every project gets `default_pool_size` server connections (its "cooks") unless it sets its own.
To give a busy app more and a quiet one fewer, add `pool_size` to the project in
`group_vars/all/vars.yml`:

```yaml
projects:
  - name: bigapp              # omit pool_size → uses default_pool_size (25)
  - name: sideproj
    pool_size: 5              # quiet project → only 5 server conns
```

That renders `pool_size=N` onto the project's `[databases]` line; the per-DB value overrides the
global `default_pool_size`. Two guardrails to remember:

- **The box is the limit, not the app.** The *sum* of all pool sizes must stay under
  `max_connections`. Ten projects can't each take 25 (`10 × 25 = 250 > 120`) — give each ~10, or
  raise the box. A deploy-time assert in the `db_stack` role **fails fast** if the totals exceed
  `max_connections − 15`, so you can't accidentally oversubscribe and hit "too many clients".
- **Past ~25, more cooks rarely help.** Only `~2–4 × cores` queries run truly in parallel, so
  bumping one app to 50–75 mostly just queues work behind the CPU. If an app is genuinely
  saturated (watch the *Connection saturation* alert in `grafana/SETUP.md`), add cores/RAM —
  vertical scaling (§9) — rather than a bigger pool.

---

## 3. PostgreSQL tuning (8 GB box)

Key non-default settings in `postgresql.conf`:

```ini
max_connections            = 120          # PgBouncer fronts the rest
shared_buffers             = 2GB          # ~25% RAM
effective_cache_size       = 6GB          # ~75% RAM (planner hint)
maintenance_work_mem       = 512MB
work_mem                   = 32MB         # per sort/hash op — keep modest
wal_compression            = on
checkpoint_completion_target = 0.9
random_page_cost           = 1.1          # SSD
effective_io_concurrency   = 200          # SSD

# Required for pgBackRest WAL archiving + PITR
wal_level                  = replica
archive_mode               = on
archive_command            = 'pgbackrest --stanza=main archive-push %p'

# Security
ssl                        = on
password_encryption        = scram-sha-256

# Observability
log_min_duration_statement = 500ms        # log slow queries
shared_preload_libraries   = 'pg_stat_statements'
```

`work_mem` is per-operation and can multiply across concurrent queries — 32 MB is safe
here; raise cautiously only if you see disk-based sorts.

---

## 4. Multi-project isolation

One cluster, hard walls between projects:

```sql
-- per project
CREATE ROLE proj_a_app LOGIN PASSWORD '...';
CREATE DATABASE proj_a OWNER proj_a_app;
REVOKE CONNECT ON DATABASE proj_a FROM PUBLIC;
GRANT  CONNECT ON DATABASE proj_a TO proj_a_app;
```

- **One DB + one role per project.** Roles can't reach other databases.
- Add each `(role, db)` to PgBouncer `[databases]` and `userlist.txt`.
- Avoid the "one shared DB with per-project schemas" pattern unless projects genuinely
  share data — separate databases make per-project backup, restore, and decommission
  trivial (just `DROP DATABASE`).

### Optional per-project extensions: pgvector

Vector search is opt-in per database. The image ships pgvector (ops doc Dockerfile), so a
project enables it with one statement; others never pay for it:

```sql
-- in the project's database
CREATE EXTENSION IF NOT EXISTS vector;

CREATE TABLE items (id bigserial PRIMARY KEY, embedding vector(1536));
-- build an approximate-NN index (cosine shown; also l2 / ip)
CREATE INDEX ON items USING hnsw (embedding vector_cosine_ops)
       WITH (m = 16, ef_construction = 128);

-- query
SELECT id FROM items ORDER BY embedding <=> $1 LIMIT 5;
```

Notes for this shared 8 GB box:
- **PgBouncer transaction mode:** pgvector works fine, but query-time tuning must use
  `SET LOCAL` inside a transaction (session-level `SET hnsw.ef_search` won't persist
  across pooled statements):
  ```sql
  BEGIN; SET LOCAL hnsw.ef_search = 100;
  SELECT id FROM items ORDER BY embedding <=> $1 LIMIT 5; COMMIT;
  ```
- **Index builds are heavy.** Raise `maintenance_work_mem` *for the build session only*,
  ensure the container `shm_size` ≥ that value (ops doc), and build during low traffic.
- **Save memory:** store `halfvec` (half-precision) for large/high-dimension sets.
- If one project's vector workload grows large, move *that* project to its own instance
  rather than letting it starve the others — the per-DB layout makes that a clean lift.

---

## 5. Networking & security

Postgres/PgBouncer must **never** be open to the public internet on a default port.

### ⚠️ Amplify managed SSR compute has no VPC / fixed IP

The Lambdas that run an Amplify-hosted Next.js app are **fully AWS-managed**. You get an
IAM "SSR compute role" to reach AWS services, but you **cannot place them in your VPC**
and they have **no stable outbound IP**. So the usual "allowlist the source IP" trick
does **not** work for the Amplify→OVH path. Access control there must be **cryptographic,
not network-based**:

1. **TLS required** end-to-end (encrypt in transit).
2. **mTLS / client certificates at PgBouncer** — only holders of a valid client cert may
   connect. This is the real access gate when you can't filter by IP.
   ```ini
   ; pgbouncer.ini — require a client cert signed by our CA
   client_tls_sslmode   = verify-full
   client_tls_ca_file   = /etc/pgbouncer/client-ca.crt
   ```
   Issue one client cert per app, ship it to Amplify via env/secret, revoke per app.
3. **Optionally** narrow the OVH firewall to **AWS's published IP ranges** for your EU
   region (`ip-ranges.json`, service `AMAZON`, your region) — broad, but shrinks the
   surface from "whole internet" to "AWS EU." Defense in depth, refresh periodically.

### When you DO control the compute (your own VPC Lambdas / the failover EC2)

If a consumer runs in **your** VPC (an API-Gateway-backed Lambda you own, the §7 failover
EC2, a bastion), you can pin a stable source IP and allowlist it on OVH:

- **NAT Gateway + Elastic IP** — VPC egress exits one static IP; allowlist `<EIP>:6432`.
  Costs ~$32/mo + data. Simplest to reason about.
- **WireGuard tunnel** — encrypted VPN VPC↔VPS; 6432 never faces the public internet.
  Cheaper, more moving parts.

```
Your VPC compute → NAT GW (static EIP)  ─┐
                                          ├─► OVH firewall allow <EIP>:6432 → PgBouncer
Amplify SSR (no VPC) → mTLS + TLS  ───────┘   (+ optional AWS-EU range allowlist)
```

### DNS: `db.example.com` (AWS Route 53)

`example.com` is hosted in **Route 53**. Point a dedicated name at the DB so apps never
hardcode an IP — this is what makes failover (§7) a DNS swap instead of a redeploy.

- **Record:** `db.example.com` → **A** record to the OVH VPS public IP, **TTL 60 s**.
  Managed as code in `cloudformation/backup-infra.yaml` (`PrimaryIp` param) — change the
  IP by re-deploying that stack. Route 53 is pure DNS (no proxy), so it carries Postgres
  TCP fine — no Cloudflare grey-cloud caveat to worry about.
- **Failover = one API call.** Repointing to the EC2's EIP is `aws route53
  change-resource-record-sets`, run as the last step of the failover script (§7) — this
  UPSERTs the record out-of-band, so CloudFormation will show drift until you fail back
  (expected). Since you're already in AWS, no third-party DNS API or token to manage.
- **Server cert via Let's Encrypt DNS-01 over Route 53.** Use the `certbot-dns-route53`
  plugin (or `lego`/`acme.sh` with Route 53) to issue the PgBouncer **server cert for
  `db.example.com`** — public trust, so `sslmode=verify-full` works without shipping a
  CA, and auto-renewal is hands-off. The **mTLS client certs** are separate and stay on
  your own private CA.
- Publishing the name advertises the box exists — that's fine; security is firewall + TLS
  + mTLS, not a hidden IP.

Hardening checklist:
- TLS required end-to-end (`client_tls_sslmode`, `ssl = on`); mTLS for Amplify clients.
- `scram-sha-256` auth everywhere; no `trust`/`md5`.
- Firewall default-deny; SSH key-only + `fail2ban`.
- Postgres listens on `127.0.0.1` only — **PgBouncer is the only thing reachable.**
- Separate low-priv app roles from the superuser; never connect the app as `postgres`.

---

## 6. Backups → object storage (pgBackRest)

`pg_dump` is fine for ad-hoc exports but is **not** a DR strategy at this scale. Use
**pgBackRest**: full/differential/incremental backups, parallel compression, and — via
WAL archiving — **Point-In-Time Recovery** to any second.

> **Repository choice: AWS S3 (chosen), region `eu-central-1` (Frankfurt)** — same region
> as the failover EC2, so the EC2 restores from the bucket in-region with no egress cost.
> The only egress paid is OVH (Warsaw) → S3 (Frankfurt) for the backup push.

`/etc/pgbackrest/pgbackrest.conf`:

```ini
[global]
repo1-type        = s3
repo1-path        = /repo
repo1-s3-bucket   = my-pg-backups
repo1-s3-endpoint = s3.eu-central-1.amazonaws.com  # AWS S3, EU (Frankfurt)
repo1-s3-region   = eu-central-1
repo1-s3-key      = <ACCESS_KEY>
repo1-s3-key-secret = <SECRET_KEY>
repo1-cipher-type = aes-256-cbc                 # encrypt at rest in the bucket
repo1-cipher-pass = <LONG_RANDOM_PASSPHRASE>

# Retention: keep 2 full backups; diffs expire with their full
repo1-retention-full      = 2
repo1-retention-diff      = 6
repo1-retention-full-type = count

process-max  = 2            # parallel compression (matches small core count)
compress-type = zst
start-fast   = y
archive-async = y           # don't stall Postgres on WAL push

[main]
pg1-path = /var/lib/postgresql/data   # matches the container's PGDATA (docker-compose.yml)
```

Schedule (cron):
```cron
# Full backup Sunday 02:10, differential other days 02:10  (off-the-:00 to spread load)
10 2 * * 0  postgres  pgbackrest --stanza=main --type=full backup
10 2 * * 1-6 postgres pgbackrest --stanza=main --type=diff backup
```

WAL is streamed continuously via the `archive_command` in §3, so RPO is seconds, not a
day. Run `pgbackrest --stanza=main check` after setup and verify `info` regularly.

---

## 7. Disaster recovery — pilot-light (on-demand, ~$0 idle)

**Chosen DR model:** nothing runs in AWS until disaster. A 1-minute **Healthchecks.io
dead-man's-switch** on the VPS emails you (with the runbook link) if the DB stops
responding. You then run **one script** that provisions a fresh EC2 from a CloudFormation
template; the instance self-restores from S3 and the script repoints `db.example.com`.
**Idle AWS cost = just S3 backup storage (~$2/mo)** — no stopped instance, no Lambda.

```
 normal:    OVH Postgres ──WAL + nightly──► S3 (eu-central-1)
            VPS cron ──SELECT 1, ping──► Healthchecks.io
 detect:    pings stop ──► email to you (runbook link)
 failover:  you run dr-failover.sh ──► CFN creates EC2 ──► userdata pulls SSM secrets,
            pgbackrest --delta restore, compose up ──► Route53 UPSERT db.example.com → new IP
 recover:   repoint DNS to rebuilt primary ──► dr-teardown.sh (stops the bill)
```

- **RPO:** ~seconds (continuous WAL archive to S3). **RTO:** ~15–40 min (provision +
  restore). Manual by design — a human decides, which removes false-positive/split-brain risk.
- Full procedure + the guardrails (confirm-before-failover, **no auto-fail-back**, fencing
  the old primary) live in the runbook: **[`runbook-failover.md`](./runbook-failover.md)**.
- Implementation: `cloudformation/dr-oncall.yaml`, `scripts/dr-failover.sh`,
  `scripts/dr-teardown.sh`, `scripts/dr-put-secrets.sh` (SSM Parameter Store, free),
  `scripts/dr-healthcheck-cron.sh`.
- **Keep safe & offline:** bucket name, region, and `repo1-cipher-pass`. Losing the cipher
  pass = losing the backups.

### When to graduate to warm/auto failover
If downtime tolerance drops below ~30 min, run a **continuous streaming replica** — the
cheapest option being a **second OVH VPS** (~$5/mo, different datacenter) with
`primary_conninfo`; promotion is seconds and RPO ~0. (A heavier AWS auto-failover stack —
EventBridge → Lambda → Step Functions — was designed and then retired as over-engineered
for one app; it's archived at `cloudformation/dr-failover.yaml.archived` and described in
[`automated-failover.md`](./automated-failover.md).) `wal_level=replica` is already set, so
either upgrade is config-only.

---

## 8. App-side connection (AWS Amplify / Lambda)

- Connect to **PgBouncer:6432**, not Postgres:5432.
- Keep the in-process client pool **tiny** (max 1–2) — Lambda concurrency is the real
  fan-out and PgBouncer is the real pool. A large per-Lambda pool just multiplies idle
  conns.
- Store credentials in **AWS Secrets Manager / SSM**, not env vars in code.
- Prisma 7 example (no `pgbouncer=true`; migration URL goes in `prisma.config.ts`):
  ```
  DATABASE_URL="postgresql://proj_a_app:***@db.example.com:6432/proj_a?connection_limit=1&sslmode=verify-full"
  DIRECT_DATABASE_URL="postgresql://proj_a_app:***@db.example.com:6432/proj_a_session?sslmode=verify-full"
  ```
  Both go through PgBouncer:6432 — the app via the transaction-mode DB, migrations via the
  session-mode virtual DB. See [`amplify-nextjs-setup.md`](./amplify-nextjs-setup.md) §1.
- Set short connect/query timeouts in the app so a stalled DB fails fast rather than
  piling up Lambda duration cost.

---

## 9. Capacity assessment for ~300 concurrent users

300 *concurrent users* ≠ 300 concurrent *queries*. Real DB concurrency is users × actions
per request × fraction actively querying — usually a small multiple. A 4 vCPU / 8 GB box
with PgBouncer transaction pooling and a sane schema (indexes, no N+1) handles this
comfortably for a typical CRUD/web workload. Watch these signals to know when to scale:

- `SHOW POOLS;` queue depth (`cl_waiting`) consistently > 0 → raise `default_pool_size`
  or add CPU.
- `pg_stat_statements` top queries → add indexes before adding hardware.
- Sustained CPU > 70% or cache hit ratio dropping → vertical bump (more RAM/cores) or
  read replica.

Vertical scaling on OVH is the easy first lever; a read replica (the §7 standby doubling
as a read scaler) is the next.

---

## 10. Build order

1. Provision VPS, OS hardening (firewall default-deny, SSH keys, fail2ban).
2. Install PostgreSQL 16; apply §3 tuning; create first project DB + role (§4).
3. Install + configure pgBackRest (§6); take first full backup; run `check`.
4. **Test a restore on a scratch box** (§7) before trusting it.
5. Install PgBouncer (§2); verify transaction-mode behavior with the app driver.
6. Network path: VPC + NAT EIP (or WireGuard) + OVH firewall allowlist (§5).
7. Point Amplify at PgBouncer:6432 (§8); load-test toward 300 users; tune pool by §9.
8. Cron the backups; set up monitoring/alerting (disk %, WAL archive lag, pool queue).
```
