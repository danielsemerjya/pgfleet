# AWS Amplify + Next.js → Postgres: Project Setup Guide

How to wire a **Next.js app hosted on AWS Amplify** to the shared PostgreSQL server
(see [`database-architecture.md`](./database-architecture.md)). Follow this per project.

## How Amplify runs your app (and why it matters)

Amplify Hosting runs Next.js SSR (versions 12–15) on **fully-managed compute** — Lambda
under the hood. Two consequences drive everything below:

1. **Many short-lived connections.** Each concurrent SSR invocation opens its own DB
   connection → **always connect through PgBouncer:6432**, never Postgres:5432, and keep
   the per-process client pool at **1**.
2. **No VPC, no fixed IP.** You cannot place Amplify SSR compute in a VPC, so the DB can't
   allowlist it by IP. Access is secured by **TLS + a client certificate (mTLS)** instead
   (see §5 of the architecture doc). Ship the client cert to the app as a secret.

---

## 1. Connection setup (Prisma 7)

> **Version note — verified against Prisma docs, 2026.** Prisma ORM **7** (GA 2025-11-19)
> **removed `directUrl`** from the datasource block; the direct connection used by the CLI
> for migrations is now configured in **`prisma.config.ts`**. Separately, with **PgBouncer
> ≥ 1.21** running `max_prepared_statements > 0` (arch §2), Prisma recommends **NOT**
> setting `pgbouncer=true` — PgBouncer serves prepared statements natively now. The pre-v7
> pattern still works on 6.x — see the fallback at the end of this section.

Two connection strings: the pooled one for the app, a direct (session-mode) one for migrations.

```bash
# .env (built at runtime from the db-server/<project>/db-client secret — never commit)
#
# No sslrootcert: the SERVER cert is public Let's Encrypt, so verify-full validates it via
# the system/Node trust store — you do NOT ship a CA file. You DO present the client cert/key
# (mTLS): write secret.client_cert/client_key to disk at startup and point sslcert/sslkey at
# them. (psql/libpq users: add sslrootcert=system.)

# App runtime → PgBouncer transaction mode. connection_limit=1 is critical on Lambda.
# No pgbouncer=true — PgBouncer 1.21+ handles prepared statements (arch §2).
DATABASE_URL="postgresql://proj_a_app:***@db.example.com:6432/proj_a?connection_limit=1&sslmode=verify-full&sslcert=/var/task/client.crt&sslkey=/var/task/client.key"

# Migrations → session-mode virtual DB (Schema Engine can't use a transaction pool).
DIRECT_DATABASE_URL="postgresql://proj_a_app:***@db.example.com:6432/proj_a_session?sslmode=verify-full&sslcert=/var/task/client.crt&sslkey=/var/task/client.key"
```

```ts
// prisma.config.ts (Prisma 7) — the direct/migration connection lives here now.
// Exact field shape: see prisma.io/docs/orm/reference/prisma-config-reference.
import { defineConfig } from "prisma/config";

export default defineConfig({
  schema: "prisma/schema.prisma",
  // CLI (migrate/introspect) connects directly via the session-mode endpoint:
  datasource: { url: process.env.DIRECT_DATABASE_URL },
});
```

```prisma
// schema.prisma — Prisma Client uses the pooled URL (via a driver adapter in v7).
datasource db {
  provider = "postgresql"
  url      = env("DATABASE_URL")   // pooled, transaction mode
}
```

> **Session-mode endpoint for migrations.** Only PgBouncer:6432 is exposed (Postgres:5432
> stays on localhost). PgBouncer supports a **per-database `pool_mode`**, so a second
> virtual DB in session mode serves migrations on the same port — no extra port opened.
> The Prisma Schema Engine doesn't support transaction pooling, so migrations *must* use
> this session endpoint (true on both Prisma 6 and 7):
> ```ini
> [databases]
> proj_a         = host=127.0.0.1 port=5432 dbname=proj_a              ; pool_mode=transaction (global)
> proj_a_session = host=127.0.0.1 port=5432 dbname=proj_a pool_mode=session
> ```

> **Prisma 6.x fallback.** Still on 6.x? Use the older pattern: `DATABASE_URL` with
> `?pgbouncer=true&connection_limit=1`, and a `directUrl = env("DIRECT_DATABASE_URL")` line
> in the `datasource` block (pointing at the session endpoint) instead of `prisma.config.ts`.

### Reuse the client across warm invocations
Declare a **module-level singleton** so a warm Lambda reuses one PrismaClient instead of
opening a fresh connection per request:

```ts
// lib/db.ts
import { PrismaClient } from "@prisma/client";
const globalForPrisma = globalThis as unknown as { prisma?: PrismaClient };
export const prisma = globalForPrisma.prisma ?? new PrismaClient();
if (process.env.NODE_ENV !== "production") globalForPrisma.prisma = prisma;
```

> Using `node-postgres`/Drizzle instead? With PgBouncer ≥ 1.21 (arch §2) you no longer
> need `prepare: false`. Just keep the client-side pool `max` at 1–2 — PgBouncer is the
> real pool.

### Running it locally
For local dev, generate the same two URLs + the mTLS client cert/key from the project's
Secrets Manager bundle with **`scripts/dev-env.sh <project>`** — it writes `client.crt` /
`client.key` and a ready `.env.local` (pooled `DATABASE_URL` + session `DIRECT_DATABASE_URL`)
with absolute local cert paths, so there's no hand-copying of secrets. (`pgfleet` maintainers:
`make dev-env PROJECT=<name>` from `private/`.)

---

## 2. amplify.yml build spec

```yaml
version: 1
frontend:
  phases:
    preBuild:
      commands:
        - npm ci
        - npx prisma generate
        # Run migrations against the session-mode endpoint. The build env has no fixed IP
        # either, but mTLS + the client cert (injected as env/secret) authorize it.
        - npx prisma migrate deploy
    build:
      commands:
        # Make non-public server env vars available to SSR at build (see §3).
        - env | grep -e API_BASE_URL >> .env.production
        - env | grep -e NEXT_PUBLIC_ >> .env.production
        - npm run build
  artifacts:
    baseDirectory: .next
    files:
      - '**/*'
  cache:
    paths:
      - node_modules/**/*
      - .next/cache/**/*
```

- `baseDirectory: .next` is what marks the app as SSR (vs static).
- Monorepo: wrap under `applications: [{ frontend: ..., appRoot: apps/web }]` and write
  env to `apps/web/.env.production`.
- **Decide where migrations run.** In `preBuild` (above) is simplest and gates deploys on
  a clean migration. The stricter alternative is a separate CI step / bastion so a build
  can't touch prod schema — choose per your risk appetite. Don't run migrations from
  request-handling SSR code.

---

## 3. Environment variables & secrets

- **`NEXT_PUBLIC_*` is shipped to the browser.** Never put DB URLs, certs, or keys behind
  that prefix. DB credentials are **server-only**.
- **Server env vars in SSR:** values set in the Amplify console are present at build; the
  `env | grep ... >> .env.production` lines make non-public ones available to SSR runtime.
- **One secret per project, created for you.** `site.yml` (and `issue-client-cert.yml`)
  uploads `db-server/<project>/db-client` to AWS Secrets Manager — a JSON bundle:
  ```json
  { "host": "db.example.com", "port": 6432, "dbname": "proj_a", "user": "proj_a_app",
    "sslmode": "verify-full", "password": "…", "client_cert": "<PEM>", "client_key": "<PEM>" }
  ```
  Grant the Amplify **SSR compute role** `secretsmanager:GetSecretValue` on
  `arn:aws:secretsmanager:<region>:<acct>:secret:db-server/<project>/db-client-*` (it uses
  short-lived IAM creds — no long-lived keys in the app). Never expose it via `NEXT_PUBLIC_*`.
- **At startup**, read the secret and: write `client_cert`/`client_key` to the Lambda FS
  (`/var/task/client.crt`, `/var/task/client.key`), then build `DATABASE_URL` (dbname
  `<project>`) and `DIRECT_DATABASE_URL` (dbname `<project>_session`) from the fields. No CA
  file is needed — the public server cert is validated by the system/Node trust store.

---

## 4. Per-project checklist

On the DB server (once per project) — all via Ansible:
- [ ] Append the project to `projects[]` in `group_vars/all/vars.yml` and its password to
      `vault_project_passwords`, then `ansible-playbook playbooks/site.yml`. That creates the
      DB + `<project>_app` role (revokes PUBLIC, arch §4), the `<project>` (transaction) and
      `<project>_session` (session) PgBouncer entries, and issues + uploads the client cert.

In the Next.js app:
- [ ] `lib/db.ts` singleton; client pool size 1.
- [ ] `schema.prisma` (pooled `url`) + `prisma.config.ts` (direct URL) — Prisma 7.
- [ ] `amplify.yml` with `prisma generate` + `migrate deploy`.

In Amplify / AWS:
- [ ] Grant the SSR compute role `GetSecretValue` on `db-server/<project>/db-client` (created
      for you); read it at startup to build the URLs and write the client cert/key to disk.
- [ ] `db.example.com` (A record, managed by the backup-infra stack) makes failover
      (arch §7) a DNS swap.
- [ ] Load test toward target concurrency; watch PgBouncer `SHOW POOLS;` (arch §9).

---

## 5. Common pitfalls

| Symptom                                   | Cause / fix                                                        |
| ----------------------------------------- | ------------------------------------------------------------------ |
| `too many connections` under load         | App bypassing PgBouncer, or `connection_limit` not set to 1.       |
| `prepared statement "s0" already exists`  | PgBouncer < 1.21 or `max_prepared_statements=0`. Upgrade + set it > 0 (arch §2); or on Prisma 6.x set `pgbouncer=true`. |
| `prisma migrate` hangs or errors          | Pointed at the transaction pool; migrations must use the **session** endpoint (`DIRECT_DATABASE_URL` via `prisma.config.ts`). |
| TLS / cert errors from Amplify            | Client cert not on the Lambda FS, or `sslmode` < `verify-full` mismatch with CA. |
| Secrets work in build but not at runtime  | Set via build-only env; fetch from Secrets Manager at runtime instead. |
