# Operations: Deployment & Monitoring

Companion to [`database-architecture.md`](./database-architecture.md). Covers **how to
run the stack (Docker)** and **how to know when it's in trouble (monitoring)**.

---

## Part A — Docker vs docker-compose vs bare metal

**Recommendation: `docker-compose`**, with one wrinkle — **pgBackRest baked into the
Postgres image** so WAL archiving works.

Why compose wins for *this* setup:
- **Failover becomes trivial.** The §7 cold-standby EC2 runs the *same* `docker-compose.yml`:
  `docker compose up`, then `pgbackrest restore` into the volume. Identical environment on
  OVH and AWS — no "works on the VPS, breaks on EC2" drift.
- **Multi-project clarity.** PgBouncer, exporters, and Postgres declared in one file,
  versioned in git.
- **Clean upgrades / rollback.** Pin image tags; `docker compose pull && up -d`.

The one gotcha: **`archive_command` runs *inside* the Postgres container**, so the
`pgbackrest` binary must live there. Use a tiny custom image:

```dockerfile
# Dockerfile.postgres
# Base on pgvector's image (= postgres:16 + pgvector) so vector search is available to any
# project that wants it; add pgBackRest for in-container archive_command.
FROM pgvector/pgvector:pg16
RUN apt-get update && apt-get install -y --no-install-recommends pgbackrest \
    && rm -rf /var/lib/apt/lists/*
```

> pgvector is only *active* in databases that run `CREATE EXTENSION vector;` — shipping it
> in the image costs nothing for projects that don't use it. See arch §4.

> **Bare-metal alternative:** install Postgres + pgBackRest directly on the host for
> maximum I/O performance and the simplest backup story, and run only the *stateless*
> companions (PgBouncer, exporters) in Docker. Valid — but you lose the "same artifact on
> VPS and EC2" reproducibility. Given the failover plan, compose is the better fit here.
>
> **Don't** dockerize Postgres without baking in pgBackRest and a **named volume** for
> `PGDATA` — a container-local data dir that vanishes on `docker rm` is how people lose
> databases.

### docker-compose skeleton

```yaml
# docker-compose.yml
services:
  postgres:
    build: { context: ., dockerfile: Dockerfile.postgres }
    restart: unless-stopped
    command: ["postgres", "-c", "config_file=/etc/postgresql/postgresql.conf"]
    volumes:
      - pgdata:/var/lib/postgresql/data
      - ./postgresql.conf:/etc/postgresql/postgresql.conf:ro
      - ./pgbackrest.conf:/etc/pgbackrest/pgbackrest.conf:ro
    ports: ["127.0.0.1:5432:5432"]      # localhost only — PgBouncer is the front door
    shm_size: "256mb"                    # raise to >= maintenance_work_mem if building
                                         # large pgvector HNSW indexes (arch §4)

  pgbouncer:
    image: edoburu/pgbouncer:latest
    restart: unless-stopped
    depends_on: [postgres]
    volumes:
      - ./pgbouncer.ini:/etc/pgbouncer/pgbouncer.ini:ro
      - ./userlist.txt:/etc/pgbouncer/userlist.txt:ro
      - ./certs:/etc/pgbouncer/certs:ro  # TLS + mTLS client CA
    ports: ["6432:6432"]                 # the only externally-reachable DB port

  postgres_exporter:
    image: quay.io/prometheuscommunity/postgres-exporter:latest
    restart: unless-stopped
    environment:
      DATA_SOURCE_NAME: "postgresql://exporter:***@postgres:5432/postgres?sslmode=disable"
    depends_on: [postgres]

  node_exporter:
    image: quay.io/prometheus/node-exporter:latest
    restart: unless-stopped
    pid: host
    volumes: ["/:/host:ro,rslave"]
    command: ["--path.rootfs=/host"]

  # Scrapes the exporters and remote_writes to Grafana Cloud (free tier).
  alloy:
    image: grafana/alloy:latest
    restart: unless-stopped
    depends_on: [postgres_exporter, node_exporter]
    env_file: .env.alloy            # GRAFANA_CLOUD_PROM_URL / _USER / _API_KEY
    volumes:
      - ./alloy/config.alloy:/etc/alloy/config.alloy:ro
    command: ["run", "/etc/alloy/config.alloy", "--server.http.listen-addr=0.0.0.0:12345"]

volumes:
  pgdata:
```

The host firewall still allows only `6432` from outside (arch §5); `5432` is bound to
`127.0.0.1` and the exporter reaches Postgres over the internal compose network.

---

## Part B — Monitoring (yes, you need it)

A 75 GB disk and continuous WAL archiving make **disk + archiving the #1 failure mode**:
if `archive_command` ever fails, WAL piles up in `pg_wal`, fills the disk, and **Postgres
stops accepting writes**. Monitoring exists mainly to catch that *before* it happens.

### Where it should live
**Don't run your only monitoring on the box you're monitoring** — if the VPS dies, so does
the dashboard that would tell you. Two good options:

1. **Grafana Cloud free tier (recommended — and you're eligible).** Run the exporters
   locally and **push** metrics to Grafana Cloud with **Grafana Alloy** (the current agent;
   it supersedes the deprecated Grafana Agent). Alerts fire from Grafana's infra, so they
   still reach you when the VPS itself is down. Zero extra box to run.

   **Free tier (verified May 2026):** 10k active metric series, 50 GB logs, 50 GB traces,
   3 users, 13-month metrics retention / 30-day logs — no charge. One DB host with
   `node_exporter` + `postgres_exporter` + PgBouncer metrics emits roughly **1.5k–4k
   series**, so a single server (even with a few projects) sits well under the 10k cap.
   Watch cardinality if you later add many exporters or high-label metrics.
2. **Self-host Prometheus + Grafana on a separate tiny instance** (e.g. the failover EC2
   while idle, or a small VPS). More control, one more thing to run.

Minimal `alloy/config.alloy` to scrape the exporters and ship to Grafana Cloud (create a
free **Access Policy token** in Grafana Cloud → put URL/user/key in `.env.alloy`):

```alloy
prometheus.scrape "exporters" {
  targets = [
    {"__address__" = "postgres_exporter:9187", job = "postgres"},
    {"__address__" = "node_exporter:9100",     job = "node"},
    {"__address__" = "pgbouncer:9127",          job = "pgbouncer"}, // pgbouncer_exporter
  ]
  forward_to = [prometheus.remote_write.grafanacloud.receiver]
}

prometheus.remote_write "grafanacloud" {
  endpoint {
    url = sys.env("GRAFANA_CLOUD_PROM_URL")
    basic_auth {
      username = sys.env("GRAFANA_CLOUD_PROM_USER")
      password = sys.env("GRAFANA_CLOUD_PROM_API_KEY")
    }
  }
}
```

> PgBouncer doesn't expose Prometheus metrics natively — add a small `pgbouncer_exporter`
> sidecar (it reads PgBouncer's `SHOW` stats) to get the `cl_waiting` / pool series in the
> alert table below.

### Backup dead-man's-switch (do this even if you do nothing else)
Wrap the backup cron with a **[Healthchecks.io](https://healthchecks.io)** ping. It alerts
when a backup *fails to run* — silence is the failure signal, which a metrics dashboard
won't catch on its own:

```cron
10 2 * * 0 postgres pgbackrest --stanza=main --type=full backup && curl -fsS https://hc-ping.com/<uuid>
```

### Alerts that matter (thresholds to start with)

| Signal | Source | Alert when | Why it matters |
| --- | --- | --- | --- |
| **Disk usage** | node_exporter | > 75% / critical > 85% | 75 GB is small; WAL can fill it fast. |
| **WAL archive failing** | `pg_stat_archiver.last_failed_time` | any recent failure | WAL accumulates → disk fills → DB halts. **Top risk.** |
| **Backup age** | Healthchecks.io / pgbackrest `info` | no successful backup in 26 h | Detect silent backup breakage. |
| **Connection saturation** | postgres_exporter | `numbackends` > 80% of `max_connections` | Approaching refusal of new logins. |
| **PgBouncer queue** | pgbouncer `SHOW POOLS` `cl_waiting` | > 0 sustained | Pool too small / DB overloaded (arch §9). |
| **CPU / load** | node_exporter | load > vCPU count, or CPU > 80% 5 min | Capacity ceiling. |
| **Memory** | node_exporter | available < 10% | Risk of OOM-killing Postgres. |
| **Slow queries** | `pg_stat_statements` | p95 latency rising | Add indexes before adding hardware. |
| **Replication lag** | `pg_stat_replication` | > 30 s (only once a standby exists) | Future, when you add streaming. |

Enable `pg_stat_statements` (already in `shared_preload_libraries`, arch §3) and import a
ready-made Postgres + PgBouncer Grafana dashboard to start fast, then trim to the table above.

### A simple, sufficient starting point
1. `node_exporter` + `postgres_exporter` in compose (above).
2. Push to **Grafana Cloud free tier** via **Alloy**; import a Postgres dashboard.
3. Alert on **disk %**, **WAL archive failure**, and **connection saturation** first.
4. **Healthchecks.io** dead-man's-switch on the backup cron.

That's ~an hour of setup and covers the failure modes that actually take this server down.

---

## Part C — Smoke-test a project connection (Secrets Manager → mTLS → psql)

After `site.yml` issues a project's cert, prove the whole path works: pull the bundle from
Secrets Manager, present the mTLS client cert, and run a query through PgBouncer. One script
does it (`scripts/test-db-connection.sh`):

```bash
./scripts/test-db-connection.sh myapp                  # uses DNS (db.example.com)
./scripts/test-db-connection.sh myapp 203.0.113.10   # before DNS is live: connect to the
                                                          # IP but still verify the cert hostname
# Needs: aws cli, jq, psql (libpq 16+). AWS_PROFILE=… if not your default profile.
```

Expected: `OK: myapp_app@myapp  PostgreSQL 16.x …`.

### What it does (the manual version)
```bash
# 1. Fetch the project's bundle (uses your AWS creds; same ones as `aws cloudformation deploy`).
JSON=$(aws secretsmanager get-secret-value --region <region> \
  --secret-id db-server/myapp/db-client --query SecretString --output text)

# 2. Write the mTLS client cert + key to disk. libpq REQUIRES the key be 0600 (else it refuses).
jq -r .client_cert <<<"$JSON" > /tmp/client.crt
jq -r .client_key  <<<"$JSON" > /tmp/client.key && chmod 600 /tmp/client.key

# 3. Connect through PgBouncer with the password (PGPASSWORD), the client cert (mTLS), and
#    verify-full. sslrootcert=system trusts the public Let's Encrypt SERVER cert via the OS
#    CA store — no CA file to ship. (No public DNS yet? add `hostaddr=<vps-ip>`.)
PGPASSWORD=$(jq -r .password <<<"$JSON") psql \
  "host=db.example.com port=6432 dbname=myapp user=myapp_app \
   sslmode=verify-full sslrootcert=system sslcert=/tmp/client.crt sslkey=/tmp/client.key" \
  -c "select current_user, current_database(), now();"
```

- **Both factors are required:** the SCRAM password *and* a client cert signed by our CA.
  Drop either and PgBouncer rejects the connection — that's the mTLS guarantee (arch §5).
- **Migrations endpoint:** swap `dbname=myapp` → `dbname=myapp_session` to test the
  session-mode virtual DB Prisma uses for `migrate deploy`.
- **`role "root"`-style errors** mean you hit Postgres directly (5432) instead of PgBouncer
  (6432) — always go through 6432.
