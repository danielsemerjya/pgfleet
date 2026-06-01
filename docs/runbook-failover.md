# Runbook: DB down → pilot-light failover

**You're reading this because an alert fired** (Healthchecks.io said `db.example.com`
stopped responding). This is the on-demand DR: nothing is running in AWS until you start
it, so failover is a deliberate, manual step. Stay calm — work top to bottom.

## 0. Confirm it's really down (1 min) — avoid a needless failover
```bash
# From your laptop:
psql "postgresql://proj_a_app@db.example.com:6432/proj_a?sslmode=verify-full..." -c 'select 1'
ssh ubuntu@<ovh-ip> 'docker compose -f /opt/db-server/docker/docker-compose.yml ps'
```
- **Transient blip / network?** Wait 2–3 min; Healthchecks recovers itself. Done.
- **VPS up but Postgres crashed?** Try `docker compose ... restart postgres` and check
  `logs postgres`. If it recovers, you're done — no failover needed.
- **VPS/provider truly down or unrecoverable?** Proceed to failover.

## 1. Fail over (provisions a fresh DR DB from S3, repoints DNS)
```bash
cd /path/to/pgfleet
export BACKUP_BUCKET=<acct>-pg-backups-<region> \
       DR_SUBNET=subnet-xxxx DR_SG=sg-xxxx \
       REPO_URL=https://github.com/you/pgfleet.git \
       HOSTED_ZONE_ID=Zxxxx AWS_REGION=<region>
./scripts/dr-failover.sh
```
This deploys `cloudformation/dr-oncall.yaml`: a fresh EC2 pulls DR secrets from SSM,
`pgbackrest restore`s the latest backup, brings up the stack, and the script repoints
`db.example.com` to it (TTL 60s → apps follow within a minute).

- **Want point-in-time** (e.g. recover to just before a bad migration)? Before running,
  edit the restore line in `dr-oncall.yaml` userdata to add
  `--type=time --target="YYYY-MM-DD HH:MM:SS+00"`.
- Expect **~15–40 min** total (instance provision + restore). RPO ≈ last archived WAL.

## 2. Verify
```bash
psql "postgresql://proj_a_app@db.example.com:6432/proj_a?sslmode=verify-full..." -c 'select count(*) from <a-known-table>'
```
Confirm apps reconnect. Snooze/resolve the Healthchecks alert if needed.

## 3. ⚠️ Do NOT auto-fail-back — fence the old primary
The DR instance is now authoritative. The recovered OVH box must come back as a *fresh
standby*, never a competing primary (split-brain = diverged data). When OVH is healthy:
1. **Keep its stack down** (`docker compose down` on OVH) until you deliberately rebuild.
2. Rebuild OVH from the new primary (fresh `pgbackrest restore` from S3, or re-sync), then
   plan a controlled cutover back during a quiet window.

## 4. Recover & stop the bill
Once the primary (OVH or a rebuilt box) is healthy and serving again:
```bash
# Repoint DNS back to the primary. The as-code way is to redeploy the backup-infra stack
# (resets db.example.com → PrimaryIp, clearing the failover drift); pass PrimaryIp=<ip>
# if the rebuilt box has a new IP. (Or a one-off `aws route53 ... UPSERT`, TTL 60.) Verify, then:
./scripts/dr-teardown.sh        # deletes the DR stack → idle AWS cost back to ~$0 (just S3)
```

## Prerequisites (set up once, before you ever need this)
- `scripts/dr-put-secrets.sh` has stashed secrets in SSM Parameter Store.
- You know your `DR_SUBNET` (public), `DR_SG` (allows 6432 in), `BACKUP_BUCKET`,
  `REPO_URL`, and `HOSTED_ZONE_ID`. Keep them in a `dr.env` you can `source`.
- **Drill it** at least once on a quiet day so the real event isn't the first run.
