#!/usr/bin/env bash
# Pilot-light failover. Deploys the thin DR EC2 (CloudFormation), configures + restores it
# with Ansible (same roles as production), and repoints db.example.com. Run from repo root
# on your Ansible control node. Nothing is billed until you run this.
# Full procedure + guardrails: docs/runbook-failover.md
#
# Required env (put in dr.env and `source` it):
#   BACKUP_BUCKET DR_SUBNET DR_VPC DR_KEYNAME ADMIN_CIDR HOSTED_ZONE_ID
set -euo pipefail
: "${BACKUP_BUCKET:?}"; : "${DR_SUBNET:?}"; : "${DR_VPC:?}"; : "${DR_KEYNAME:?}"
: "${ADMIN_CIDR:?}"; : "${HOSTED_ZONE_ID:?}"
REGION="${AWS_REGION:-eu-central-1}"
RECORD="${RECORD:-db.example.com}"
STACK="db-dr-oncall"

echo "==> [1/4] Deploy thin DR EC2 (CloudFormation)…"
aws cloudformation deploy --region "$REGION" --stack-name "$STACK" \
  --template-file cloudformation/dr-oncall.yaml --capabilities CAPABILITY_IAM \
  --parameter-overrides BackupBucket="$BACKUP_BUCKET" Subnet="$DR_SUBNET" VpcId="$DR_VPC" \
    AdminCidr="$ADMIN_CIDR" KeyName="$DR_KEYNAME"

IP=$(aws cloudformation describe-stacks --region "$REGION" --stack-name "$STACK" \
  --query "Stacks[0].Outputs[?OutputKey=='PublicIp'].OutputValue" --output text)

echo "==> [2/4] Wait for SSH on $IP…"
for i in $(seq 1 30); do nc -z -w3 "$IP" 22 && break || sleep 10; done

echo "==> [3/4] Configure + restore via Ansible…"
ansible-playbook ansible/playbooks/dr-restore.yml -i "${IP}," -u ubuntu

echo "==> [4/4] Repoint $RECORD -> $IP (TTL 60)…"
aws route53 change-resource-record-sets --hosted-zone-id "$HOSTED_ZONE_ID" --change-batch "{
  \"Changes\":[{\"Action\":\"UPSERT\",\"ResourceRecordSet\":{
    \"Name\":\"$RECORD\",\"Type\":\"A\",\"TTL\":60,
    \"ResourceRecords\":[{\"Value\":\"$IP\"}]}}]}" >/dev/null

echo "Failover complete → $RECORD = $IP (apps follow within ~60s)."
echo "Do NOT auto-fail-back. When OVH is rebuilt: repoint DNS, then ./scripts/dr-teardown.sh"
