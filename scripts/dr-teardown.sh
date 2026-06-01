#!/usr/bin/env bash
# Phase 5 — delete the DR stack after the primary has recovered, to stop EC2 billing.
# Make sure db.example.com points back at the recovered primary FIRST.
set -euo pipefail
REGION="${AWS_REGION:-eu-central-1}"
STACK="db-dr-oncall"

read -r -p "DNS already repointed to the recovered primary? Tearing down DR. Continue? [y/N] " a
[[ "${a:-N}" =~ ^[Yy]$ ]] || { echo "aborted"; exit 1; }

aws cloudformation delete-stack --region "$REGION" --stack-name "$STACK"
aws cloudformation wait stack-delete-complete --region "$REGION" --stack-name "$STACK"
echo "DR stack deleted. Idle AWS cost back to just S3 backup storage."
