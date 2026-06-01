# Connecting to a project DB with DBeaver

This DB is reachable only over **TLS + mTLS** through PgBouncer on port **6432** (Postgres
itself is localhost-only — see [database-architecture.md](./database-architecture.md) §5). So a
GUI client needs three things: the project's **password**, its **client certificate**, and the
matching **private key**. This guide wires all of that into DBeaver.

> **The one gotcha:** DBeaver uses the PostgreSQL **JDBC** driver, which requires the client key
> in **PKCS#8 DER** format — the PEM `client.key` from Secrets Manager will *not* load. The
> helper below produces a ready `client.pk8` for you.

---

## 1. Get the certs + connection details

Run the helper for your project (it pulls the `db-server/<project>/db-client` bundle from
Secrets Manager and writes the cert, key, and the DER key DBeaver needs):

```bash
./scripts/dev-env.sh <project>          # e.g. myapp   → writes to ./.dev/<project>/
# pgfleet maintainers, from the repo root:  make dbeaver PROJECT=<project>   → writes to private/dev/<project>/
```

It writes into the output dir and prints a **DBeaver (PostgreSQL)** block with every field
filled in:

```
client.crt    ← Client Certificate (PEM)
client.pk8    ← Client Key, PKCS#8 DER  ← give DBeaver THIS one, not client.key
.env.local    ← (for Next.js; ignore for DBeaver)
```

**Manual alternative** (no helper): fetch the bundle, then convert the key yourself:

```bash
aws secretsmanager get-secret-value --region <region> \
  --secret-id db-server/<project>/db-client --query SecretString --output text > bundle.json
jq -r .client_cert bundle.json > client.crt
jq -r .client_key  bundle.json > client.key
openssl pkcs8 -topk8 -inform PEM -outform DER -in client.key -out client.pk8 -nocrypt
jq -r '.host,.dbname,.user,.password' bundle.json   # the rest of the fields
```

---

## 2. Create the connection in DBeaver

**Database → New Database Connection → PostgreSQL.**

### Main tab
| Field | Value |
|-------|-------|
| Host | `db.<your-domain>` (e.g. `db.example.com`) |
| Port | `6432` |
| Database | `<project>_session` *(recommended — see §4)*, or `<project>` |
| Username | `<project>_app` |
| Password | the bundle's `password` |
| Save password | ✅ (locally) |

### SSL tab  (check **Use SSL**)
| Field | Value |
|-------|-------|
| SSL mode | **verify-full** |
| CA Certificate | your OS CA bundle — `/etc/ssl/cert.pem` (macOS) or `/etc/ssl/certs/ca-certificates.crt` (Debian/Ubuntu). **Required** — see §3 |
| Client Certificate | `…/client.crt` |
| Client Certificate Key | `…/client.pk8`  ← the **PKCS#8 DER** key, not `client.key` |

### PostgreSQL tab
- Uncheck **Show all databases** (you connect to one virtual DB; don't let DBeaver enumerate
  the pooler). Optionally set the default schema to `public`.

Click **Test Connection ▸**. You should authenticate and see the server version. Done.

---

## 3. Why you must set a CA file (the pgjdbc gotcha)
Because you supply a **client** certificate, DBeaver's PostgreSQL driver switches to pgjdbc's
`LibPQFactory`, which **requires an explicit root certificate and does *not* use the JVM
truststore**. With CA Certificate left empty it falls back to `~/.postgresql/root.crt` and fails
with *"Could not open SSL root certificate file …"*. The **server** cert is public Let's
Encrypt, so point CA Certificate at your **OS CA bundle** — it already trusts LE's ISRG roots:
- macOS: `/etc/ssl/cert.pem` (or Homebrew `/opt/homebrew/etc/ca-certificates/cert.pem`)
- Debian/Ubuntu: `/etc/ssl/certs/ca-certificates.crt`

The client cert/key you provide is the other half — mutual TLS — which is what PgBouncer's
`client_tls_ca` verifies. (`scripts/dev-env.sh` prints the detected bundle path for you.)

## 4. Which database — `_session` or plain?
PgBouncer runs the plain `<project>` DB in **transaction** pooling and exposes a second virtual
DB `<project>_session` in **session** pooling on the same port (arch §2).

- **Use `<project>_session` for interactive DBeaver work.** A GUI holds a session and issues
  `SET search_path`, uses temp tables, and keeps state across statements — session pooling
  preserves that. This is the same endpoint Prisma migrations use.
- **Use `<project>`** if you specifically want to exercise the app's pooled (transaction-mode)
  path. It works for queries, but session-scoped state and long-open transactions can behave
  unexpectedly because each transaction may land on a different server connection.

---

## 5. Troubleshooting

| Symptom | Cause / fix |
|---------|-------------|
| `Could not open SSL root certificate file …/.postgresql/root.crt` | CA Certificate is empty. Set it to your OS CA bundle (§3) — pgjdbc needs an explicit root when a client cert is present. |
| `Could not read SSL key file` / key load error | You pointed at `client.key` (PEM). Use `client.pk8` (PKCS#8 DER). |
| `SSL error: certificate verify failed` | The CA bundle you set doesn't contain LE's root. Use `/etc/ssl/cert.pem` or a Homebrew bundle (§3). |
| `password authentication failed` | Wrong password, or you targeted `5432` — it must be **6432** (PgBouncer). |
| `no pg_hba.conf entry … no client certificate` | Client cert/key not set, or key in the wrong format. Re-check the SSL tab. |
| Hangs / odd errors mid-session, `SET` not sticking | You're on the transaction-mode `<project>` DB — switch to `<project>_session` (§4). |
| `prepared statement "s0" already exists` | Rare with our `max_prepared_statements>0`; if it appears, use `<project>_session`. |
| Can't list other databases | Expected — PgBouncer exposes only the configured virtual DBs. Uncheck "Show all databases". |

> **Keep the key safe.** `client.pk8` / `client.key` are credentials. They're written under a
> gitignored `dev/` (or `.dev/`) directory — don't move them somewhere tracked, and don't share
> the connection export (it embeds the key path + password).
