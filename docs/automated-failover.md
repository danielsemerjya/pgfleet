# Automated Health Check & Failover (ARCHIVED / not the chosen design)

> **Superseded.** The project chose the simpler **pilot-light** DR instead — manual,
> human-in-the-loop, ~$0 idle — see [`runbook-failover.md`](./runbook-failover.md) and
> §7 of [`database-architecture.md`](./database-architecture.md). The fully-automated
> watchdog below (EventBridge → Lambda → Step Functions) was designed and then retired as
> over-engineered for a single app; its template is archived at
> `cloudformation/dr-failover.yaml.archived`. Kept here only for reference / if you later
> run a warm replica and want auto-promotion.

An AWS-native watchdog that monitors `db.example.com` and can drive the §7 failover
(see [`database-architecture.md`](./database-architecture.md)). **Optional and advanced** —
read the risks first; the safe default is *detect + alert + one-click approve*.

## ⚠️ Read this before automating execution

1. **Split-brain.** If OVH is actually alive but unreachable from AWS (a transient
   network blip), promoting the EC2 + flipping DNS creates **two primaries** writing
   diverging data. This is the dominant risk. Mitigations: a failure *threshold* + a
   *second-opinion* check before acting, DNS cutover with low TTL, **fencing** the old
   primary, and **no automatic fail-back**.
2. **Cold standby ⇒ minutes, not seconds.** The standby restores from S3 (RTO 10–30 min).
   Automation only saves human reaction time. If you want fast, hands-off failover to be
   genuinely worthwhile, run the standby **warm** (streaming replica) — then promotion is
   seconds and RPO ~0. See "Warm-standby variant" below.
3. **Recommended posture for cold standby: approval gate.** Detect automatically, alert
   immediately, and require a one-click human confirm to *execute*. Fully unattended is
   supported but only with all guardrails on.

---

## Architecture

```
EventBridge Scheduler (every 1 min)
        │ invoke
        ▼
  db-healthcheck Lambda ──SELECT 1 over mTLS──► db.example.com:6432 (OVH)
        │  read/write state
        ▼
   DynamoDB  (consecutive_failures, current_primary, failover_lock, generation)
        │  threshold tripped + second-opinion fails
        ▼
   SNS "INITIATING" ──► [approval gate?] ──► Step Functions: FAILOVER
        │                                          │
        │                                          ├─ start EC2 (or promote warm replica)
        │                                          ├─ SSM Run Command: pgbackrest --delta restore; start PG; check
        │                                          ├─ fence old primary (best-effort)
        │                                          ├─ Route53 UPSERT db.example.com → EC2 EIP
        │                                          └─ DynamoDB primary=EC2; release lock
        ▼
   SNS "COMPLETE" / "FAILED"
```

### Components (all in your AWS region)

| Component | Role |
| --- | --- |
| **EventBridge Scheduler** | Fires the health-check Lambda every 1 min. Negligible cost. |
| **`db-healthcheck` Lambda** | Connects `db.example.com:6432`, runs `SELECT 1` (3 s timeout) as a low-priv `healthcheck` role, using an **mTLS client cert** from Secrets Manager. Updates DynamoDB. **No VPC needed** — rides the same mTLS path as Amplify (arch §5), so no NAT Gateway cost. |
| **DynamoDB table** | State + the **failover lock** (conditional write → idempotency, no double/flapping failover). |
| **SNS topic** | Email/Slack at INITIATING / COMPLETE / FAILED / RECOVERED. |
| **Step Functions** | Orchestrates the multi-step failover with retries/waits — more robust than one Lambda. |
| **SSM Run Command** | Runs `pgbackrest restore` etc. on the EC2 **without SSH keys** (uses the instance's SSM agent + IAM). |

---

## The decision logic (false-positive resistant)

```
on each tick:
  ok = try SELECT 1 (timeout 3s)
  if ok:
     reset consecutive_failures = 0
     if state == DEGRADED: state = HEALTHY; SNS "RECOVERED"
     return
  # failure path
  consecutive_failures += 1
  if consecutive_failures < THRESHOLD (e.g. 3):        # ~3 min of sustained failure
     state = DEGRADED; return
  # second opinion: re-check after short delay AND/OR from a different vantage
  if second_opinion_ok: reset; return                  # was a blip
  if current_primary != OVH: return                    # already failed over
  if not acquire_lock(): return                         # failover already running
  SNS "INITIATING FAILOVER"
  [approval gate]                                       # optional human confirm
  start Step Functions failover
```

Guardrails that keep it safe:
- **Threshold + window** — never act on a single blip.
- **Second-opinion check** — a re-test (and ideally from a second region / a Route 53
  health check) before committing.
- **Lock** — DynamoDB conditional write prevents concurrent or repeated failover.
- **No auto-fail-back** — once primary = EC2, returning to OVH is a *deliberate manual*
  operation (rebuild OVH as the new standby, then cut over). Auto-fail-back causes flapping
  and split-brain.

---

## Fencing the old primary (split-brain defense)

The goal: ensure the old OVH primary cannot keep taking writes once we promote EC2.

- **DNS + low TTL** does most of it — apps follow `db.example.com` to EC2 within ~60 s.
- **Best-effort cordon:** if OVH is reachable, the failover SM stops PgBouncer/Postgres
  there (via SSH/SSM) so stale-DNS clients can't write. If OVH is unreachable (the usual
  failover trigger), you rely on DNS + the rule below.
- **When OVH comes back, it must return as a STANDBY, not a primary.** Don't let it
  auto-resume serving writes. Practically: keep its `docker compose` stack *down* until you
  rebuild it from the new primary, then bring it up as the replica. A `generation` counter
  in DynamoDB records which node is authoritative so a recovered OVH can't silently win.

---

## Approval gate (recommended for cold standby)

Insert a Step Functions **`waitForTaskToken`** (or a simple "click this link" via SNS +
API Gateway) between detection and execution:

- SNS alert: *"OVH DB unreachable 3 min. Approve failover? [Approve] [Dismiss]"*
- Approve → SM proceeds. Dismiss / 10-min timeout → SM aborts, stays degraded, keeps
  alerting. This keeps a human in the loop for the destructive step while still automating
  detection and the entire mechanical failover.

---

## Warm-standby variant (if you want fast, hands-off failover)

Run the EC2 **continuously as a streaming replica** instead of stopped:

- `wal_level = replica` is already set (arch §3); configure `primary_conninfo` to stream
  from OVH.
- Failover = **promote** (`pg_ctl promote` / `SELECT pg_promote()`) instead of restore →
  **seconds**, RPO ~0.
- Now fully-automatic failover is genuinely worth it; the same Lambda/Step Functions drive
  it, just "promote" replaces "start + restore."
- Cost: always-on EC2 + cross-cloud replication bandwidth. This is the upgrade path when
  downtime tolerance drops below ~30 min.

---

## Cost (cold-standby auto-detect)

Effectively free: EventBridge + ~43k Lambda invocations/mo + on-demand DynamoDB + SNS +
occasional Step Functions runs all sit in/near the AWS free tier. The standby EC2 is still
just EBS storage while stopped (arch §7). **No NAT Gateway** since the checker Lambda uses
mTLS rather than IP-allowlisting.

## Build checklist

- [ ] `healthcheck` low-priv role on Postgres (`GRANT CONNECT`; can run `SELECT 1`).
- [ ] mTLS client cert for the checker, stored in Secrets Manager.
- [ ] DynamoDB table (`pk=db`, attrs above); SNS topic + subscription (email/Slack).
- [ ] `db-healthcheck` Lambda + EventBridge Scheduler (1 min) with the logic above.
- [ ] Step Functions failover SM: start EC2 → SSM restore → fence → Route53 UPSERT →
      state update. Reuse the §7 script commands as SSM documents.
- [ ] Decide: **approval gate** (recommended) vs fully unattended.
- [ ] **Test it**: simulate OVH outage (block the checker / stop PgBouncer) in a drill and
      confirm detect → (approve) → restore → DNS cutover end-to-end.
```
