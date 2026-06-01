# SETUP CHECKLIST — bare commands (Ansible/CFN)

Replace `<...>` (use the same AWS region everywhere). Prefer one-liners? Use the `make` targets
(`make backup-infra`, `make site`, …) — see ../README.md. Below are the raw commands.

## 1. AWS backup infra (persistent, once — from laptop)
```bash
aws cloudformation deploy --region <region> --stack-name db-backup-infra \
  --template-file cloudformation/backup-infra.yaml --capabilities CAPABILITY_NAMED_IAM \
  --parameter-overrides HostedZoneId=<zone-id> PrimaryIp=<vps-ip> RecordName=db.<your-domain>
# ^ also creates the db.<your-domain> A record → PrimaryIp (TTL 60). No IP yet? re-deploy after step 2.
aws cloudformation describe-stacks --region <region> --stack-name db-backup-infra \
  --query "Stacks[0].Outputs"     # BackupBucketName; OVH AWS creds in SM: db-server/ovh-aws-creds
```

## 2. Order OVH VPS (Ubuntu 24.04), note its IP.

## 3. Control node (laptop)
```bash
cd ansible
ansible-galaxy collection install -r requirements.yml
pip install boto3 botocore            # community.aws → Secrets Manager push
cp group_vars/all/vault.example.yml group_vars/all/vault.yml
$EDITOR group_vars/all/vault.yml      # superpass, ovh AWS key/secret (S3+route53), cipher pass, ca pass, grafana, project pw
ansible-vault encrypt group_vars/all/vault.yml
printf '<vault-password>' > .vault_pass && chmod 600 .vault_pass
$EDITOR inventory/hosts.yml           # ansible_host: <vps-ip>
$EDITOR group_vars/all/vars.yml       # domain, letsencrypt_email, backup_s3_bucket, grafana_prom_url,
                                      #   healthcheck_* urls, projects[]
```

## 4. Build (Phases 0–4 + per-project client certs, one run)
```bash
ansible-playbook playbooks/site.yml                 # full (last play issues 1 client cert/project → Secrets Manager)
# or slices:
ansible-playbook playbooks/site.yml --tags common
ansible-playbook playbooks/site.yml --tags certs
ansible-playbook playbooks/site.yml --tags db
ansible-playbook playbooks/site.yml --tags projects
ansible-playbook playbooks/site.yml --tags backups
ansible-playbook playbooks/site.yml --tags monitoring
ansible-playbook playbooks/site.yml --check --diff  # dry run
```

## 5. Verify DNS + (extra) certs
```bash
dig +short db.example.com                        # → <vps-ip>  (A record created by step 1's stack)
./scripts/test-db-connection.sh <project>          # smoke-test: secret → mTLS → psql (ops doc Part C)
# Per-project certs are issued by site.yml (step 4) → secret db-server/<project>/db-client.
# Only for an EXTRA role not in projects[] (2nd app, read-only role):
ansible-playbook playbooks/issue-client-cert.yml -e cn=<role_name>
```

## Add a project later
```bash
$EDITOR group_vars/all/vars.yml                    # append to projects[]
ansible-vault edit group_vars/all/vault.yml        # add vault_project_passwords.<name>
ansible-playbook playbooks/site.yml                # creates DB/role + issues its client cert + uploads secret
```

## Phase 5 — DR (set once; run only on failure, from laptop)
```bash
# dr.env:  BACKUP_BUCKET= DR_SUBNET= DR_VPC= DR_KEYNAME= ADMIN_CIDR= HOSTED_ZONE_ID= AWS_REGION=<region>
source dr.env && ./scripts/dr-failover.sh           # full steps: docs/runbook-failover.md
./scripts/dr-teardown.sh                            # after primary recovers
```
