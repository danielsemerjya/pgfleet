# Grafana Cloud — setup inputs

Free tier (verified 2026): **10k active series, 50 GB logs, 3 users, 13-month metric
retention**. One DB host emits ~1.5–4k series — well within limits.

## 1. Create the stack + token
1. Sign up at grafana.com → create a **Free** stack (region near eu-central-1, e.g. EU).
2. **Connections → Add new connection → Prometheus → "Via Grafana Alloy"** (or "Hosted
   Prometheus metrics"). Note the **remote_write URL**, the **username/instance ID**, and
   create an **Access Policy token** with scope `metrics:write`.
3. Put those three into `docker/alloy/.env.alloy` (copy from `.env.alloy.example`):

   ```
   GRAFANA_CLOUD_PROM_URL=https://prometheus-prod-XX-prod-eu-west-X.grafana.net/api/prom/push
   GRAFANA_CLOUD_PROM_USER=<instance id>
   GRAFANA_CLOUD_PROM_API_KEY=glc_xxx
   ```

4. `docker compose -f docker/docker-compose.yml up -d alloy` — metrics flow within ~1 min.
   Verify in Grafana **Explore** with `up{instance="db.example.com"}`.

## 2. Dashboards to import (Grafana → Dashboards → Import by ID)
| ID | Dashboard |
|----|-----------|
| 1860 | Node Exporter Full |
| 9628 | PostgreSQL Database (postgres_exporter) |
| varies | PgBouncer (search "pgbouncer" in the import gallery) |

## 3. Alert rules (Grafana → Alerting → Alert rules → New)
Wire a contact point first (email/Slack) under **Alerting → Contact points**. These match
the threshold table in `../docs/operations-deployment-monitoring.md`:

| Alert | Expression (PromQL) | Fire when |
|-------|---------------------|-----------|
| Disk filling | `100 * (1 - node_filesystem_avail_bytes{mountpoint="/host"} / node_filesystem_size_bytes{mountpoint="/host"})` | > 75 (warn) / > 85 (crit) |
| **WAL archive failing** | `pg_stat_archiver_failed_count` (increase over 10m) | `increase(...[10m]) > 0` |
| Backup too old | external — Healthchecks.io (no successful backup in 26h) | dead-man's-switch |
| **Connection saturation** ("kitchen filling up") | `sum(pg_stat_activity_count) / pg_settings_max_connections` | > 0.8 for 5m |
| PgBouncer queue ("a line is forming") | `pgbouncer_pools_client_waiting_connections` | > 0 for 5m — **needs a PgBouncer exporter** (see note ↓) |
| CPU high | `1 - avg(rate(node_cpu_seconds_total{mode="idle"}[5m]))` | > 0.8 for 5m |
| Low memory | `node_memory_MemAvailable_bytes / node_memory_MemTotal_bytes` | < 0.1 |

> The two that actually take this server down are **Disk filling** and **WAL archive
> failing** — set those up first. Keep the Healthchecks.io ping in `scripts/backup.sh`.

> **Connection alerts — which to use.** *Connection saturation* works out of the box: it's built
> from `postgres_exporter` (already scraped), and it's the "kitchen filling up → about to refuse
> connections" warning — **set this one up.** The *PgBouncer queue* alert ("a line is forming")
> is an earlier signal, but `pgbouncer_pools_client_waiting_connections` is produced by a
> **PgBouncer exporter that is NOT part of the stack** by default — so that row won't fire until
> you add one. Adding it is non-trivial (PgBouncer's admin console sits behind the same mTLS as
> the data port), so saturation is the recommended alert unless you specifically want the queue
> metric. The deploy-time pool-budget assert (`db_stack`) already prevents *static*
> oversubscription; this alert covers *load-driven* saturation. See
> [database-architecture.md](../docs/database-architecture.md) §2.
