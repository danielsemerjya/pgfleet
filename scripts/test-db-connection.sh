#!/usr/bin/env bash
# Smoke-test a project's DB connection END TO END: pull the project's bundle from AWS
# Secrets Manager, present its mTLS client cert, and run a query through PgBouncer.
# Proves Secrets Manager -> mTLS -> PgBouncer -> Postgres all work for that project.
#
# Usage:  ./scripts/test-db-connection.sh <project> [vps-ip]
#   <project>  e.g. myapp            (secret = db-server/<project>/db-client)
#   [vps-ip]   optional: connect to this IP while still verifying the db.example.com
#              server cert — handy before DNS is live (libpq 'hostaddr' trick).
# Env:    AWS_REGION (default eu-central-1); AWS_PROFILE if not your default profile.
# Needs:  aws cli, jq, psql (libpq 16+ for sslrootcert=system).
set -euo pipefail

PROJECT="${1:?usage: $0 <project> [vps-ip]   e.g. $0 myapp}"
HOSTADDR="${2:-}"
REGION="${AWS_REGION:-eu-central-1}"
SECRET="db-server/${PROJECT}/db-client"

echo "==> Fetching secret ${SECRET} from Secrets Manager (${REGION})…"
JSON="$(aws secretsmanager get-secret-value --region "$REGION" \
  --secret-id "$SECRET" --query SecretString --output text)"

host="$(jq -r .host     <<<"$JSON")"
port="$(jq -r .port     <<<"$JSON")"
db="$(  jq -r .dbname   <<<"$JSON")"
user="$(jq -r .user     <<<"$JSON")"
pass="$(jq -r .password <<<"$JSON")"

# Client cert/key -> a private temp dir. libpq REFUSES a key with group/world access,
# so it must be 0600. Cleaned up on exit (don't leave the private key lying around).
tmp="$(mktemp -d)"; trap 'rm -rf "$tmp"' EXIT
jq -r .client_cert <<<"$JSON" > "$tmp/client.crt"
jq -r .client_key  <<<"$JSON" > "$tmp/client.key"
chmod 600 "$tmp/client.key"

# verify-full needs a CA bundle for the public Let's Encrypt SERVER cert. libpq 16+ accepts
# the special value "system" (OS trust store); older libpq (e.g. 14) needs a real file, so
# pick the first bundle that exists. Override with PGSSLROOTCERT=/path or SSL_CERT_FILE.
sslroot="system"
for c in "${PGSSLROOTCERT:-}" "${SSL_CERT_FILE:-}" \
         /etc/ssl/cert.pem \
         /opt/homebrew/etc/ca-certificates/cert.pem \
         /opt/homebrew/etc/openssl@3/cert.pem \
         /etc/ssl/certs/ca-certificates.crt; do
  [ -n "$c" ] && [ -f "$c" ] && { sslroot="$c"; break; }
done
echo "==> Using CA bundle: ${sslroot}"

# sslroot         -> verify the public Let's Encrypt SERVER cert.
# sslcert/sslkey  -> present OUR mTLS client cert (what PgBouncer's client_tls_ca verifies).
conn="host=$host port=$port dbname=$db user=$user sslmode=verify-full sslrootcert=$sslroot"
conn="$conn sslcert=$tmp/client.crt sslkey=$tmp/client.key"
if [ -n "$HOSTADDR" ]; then
  conn="$conn hostaddr=$HOSTADDR"            # reach this IP, still verify the cert for $host
  echo "==> Using hostaddr=${HOSTADDR} (verifying server cert for ${host})"
fi

echo "==> Connecting as ${user} -> ${host}:${port}/${db}  (mTLS + verify-full)…"
PGPASSWORD="$pass" psql "$conn" -At \
  -c "select 'OK: '||current_user||'@'||current_database()||'  '||version();"

echo "✓ ${PROJECT}: Secrets Manager -> mTLS -> PgBouncer -> Postgres all good."
