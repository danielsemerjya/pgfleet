# Ansible automation — why, what, how

## Why
The setup used to be a sequence of hand-run shell scripts ("did I already run that?").
Ansible replaces them with **one idempotent definition** that:
- configures the **OVH primary** and the **DR EC2** from the *same roles* — so the failover
  box is provably identical to production;
- is **re-runnable** — it converges to the desired state, no ordering guesswork;
- keeps **secrets encrypted in the repo** (Ansible Vault) instead of hand-made files;
- makes **projects declarative** — add a DB by editing a list and re-running.

Provisioning (creating the VM) stays separate: **CloudFormation** makes the AWS pieces
(`backup-infra.yaml` = S3 + IAM; `dr-oncall.yaml` = the DR EC2); Ansible does all *config*.
OVH VPS is ordered manually. This is the standard "Terraform/CFN provisions, Ansible
configures" split.

## What (layout)
```
ansible/
  ansible.cfg                  # inventory path, become, vault password file
  requirements.yml             # collections: community.docker, community.crypto, community.general, community.aws
  inventory/hosts.yml          # groups: primary (OVH), dr (filled at failover)
  group_vars/all/vars.yml      # all non-secret config (tuning, domain, projects[])
  group_vars/all/vault.yml     # ENCRYPTED secrets (gitignored; copy from vault.example.yml)
  playbooks/
    site.yml                   # full primary setup; final play issues 1 client cert/project
    dr-restore.yml             # configure a DR EC2 + restore from S3
    issue-client-cert.yml      # thin wrapper over client_certs for ONE ad-hoc CN
  roles/
    common/      # apt, swap, Docker (official repo), ufw, fail2ban, auto-updates
    certs/       # client CA (control node) + Let's Encrypt server cert (DNS-01/Route 53)
    db_stack/    # render docker/ configs from templates + `docker compose up` (+DR restore)
    projects/    # create DB + role per projects[] entry (pgvector optional)
    backups/     # pgBackRest stanza-create + backup cron + liveness dead-man's-switch
    monitoring/  # exporter role + bring up exporters/Alloy → Grafana Cloud
    client_certs/# sign an app's mTLS client cert + push it to Secrets Manager (control node)
```
The role templates are the **single source of truth** for `postgresql.conf`,
`pgbouncer.ini`, `pgbackrest.conf`, the compose file, etc. — they're rendered onto the host
at `/opt/db-server/docker/`.

## How — one-time control-node setup
```bash
cd ansible
pip install ansible            # or pipx; needs the 'cryptography' lib for the certs role
pip install boto3 botocore     # community.aws (client_certs → Secrets Manager) needs it
ansible-galaxy collection install -r requirements.yml

# Secrets
cp group_vars/all/vault.example.yml group_vars/all/vault.yml
#   fill real values, then:
ansible-vault encrypt group_vars/all/vault.yml
echo 'your-vault-password' > .vault_pass && chmod 600 .vault_pass   # or use --ask-vault-pass

# Inventory + non-secret config
$EDITOR inventory/hosts.yml          # set the OVH VPS IP
$EDITOR group_vars/all/vars.yml      # domain, email, backup_s3_bucket, projects[], grafana url
```

## How — run it
```bash
# Everything on the primary (Phases 0–4 in one converging run):
ansible-playbook playbooks/site.yml

# Just one area (tags map to the old phases):
ansible-playbook playbooks/site.yml --tags common      # host prep + Docker
ansible-playbook playbooks/site.yml --tags certs       # CA + LE server cert
ansible-playbook playbooks/site.yml --tags db          # Postgres + PgBouncer
ansible-playbook playbooks/site.yml --tags projects    # create project DBs/roles
ansible-playbook playbooks/site.yml --tags backups     # stanza + cron
ansible-playbook playbooks/site.yml --tags monitoring  # exporters + Alloy

# Dry run / see changes:
ansible-playbook playbooks/site.yml --check --diff

# Add a project: edit projects[] in vars.yml + its password in vault, then re-run site.yml.
# It creates the DB/role AND issues + uploads that project's client cert in one pass:
ansible-playbook playbooks/site.yml

# Need a cert for an EXTRA role not in projects[] (a 2nd app, a read-only role)?
ansible-playbook playbooks/issue-client-cert.yml -e cn=<role_name>
```

## How — disaster recovery (Phase 5)
Provisioning + config are wrapped by `scripts/dr-failover.sh`:
1. `cloudformation/dr-oncall.yaml` → a thin bare EC2.
2. `ansible-playbook playbooks/dr-restore.yml -i "<ip>,"` → same roles + restore from S3.
3. Route 53 repoint.
See [runbook-failover.md](runbook-failover.md). `scripts/dr-teardown.sh` to recover.

## Notes & caveats
- **Vault is mandatory** — every template pulls secrets from `vault_*` vars. Never commit
  the decrypted `vault.yml`.
- **Postgres superuser password** is set only on first init (empty volume). Changing the
  vault value later won't re-set it — `ALTER USER postgres ...` manually if needed.
- **The certs role** runs the CA tasks on the control node (`delegate_to: localhost`) and
  needs the `cryptography` Python lib there. The CA key is sensitive — it's gitignored;
  keep it offline/backed up (it signs every app's client cert).
- **certbot/Route 53** uses the OVH host's single AWS key pair (`vault_ovh_aws_*`, the same
  one pgBackRest uses for S3). The `backup-infra` stack grants that IAM user both S3 and
  `route53:ChangeResourceRecordSets` on the zone. The certs role writes the key to
  `/root/.aws/credentials` so the system `certbot.timer` can renew unattended.
- **Steady-state DNS is CloudFormation, not Ansible.** The `db.example.com` A record lives
  in `backup-infra.yaml` (`PrimaryIp` param, TTL 60). Change the IP by re-deploying that
  stack. `dr-failover.sh` UPSERTs the same record to the EC2 during a disaster (CFN then
  shows drift — expected); fail-back = redeploy `backup-infra`.
- **Per-project client certs** are minted by the `client_certs` role — a separate
  `localhost` play at the end of `site.yml` (it needs the CA key + your AWS creds, neither
  of which belong on the VPS). It signs `<project>_app`'s cert and pushes
  `db-server/<project>/db-client` (cert + key + connection info) to Secrets Manager. It uses
  **your local AWS identity** (the CloudFormation-deploy creds), **not** the VPS IAM user —
  and the **CA private key is never uploaded**. The app's own execution role needs
  `secretsmanager:GetSecretValue` on that path. Skip with `--skip-tags client-certs`.
- **Idempotency:** role/project SQL uses `ALTER ROLE … PASSWORD` each run (so it reports
  "changed"), as does the Secrets Manager push (`overwrite: true`) — but the end state is
  stable. Keys/certs are not regenerated while valid. `--check` is safe to preview.
