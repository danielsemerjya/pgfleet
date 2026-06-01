# ─────────────────────────────────────────────────────────────────────────────
# pgfleet — operator Makefile. SAFE TO COMMIT: there are NO secrets in this file.
# Your real IDs live in private/config.mk (gitignored). Bootstrap once:
#   cp config.example.mk private/config.mk   &&   $EDITOR private/config.mk
# Run from the repo root:  make <target>   (bare `make` prints help)
# ─────────────────────────────────────────────────────────────────────────────

# Pull in your prefilled IDs if present. Leading '-' = don't error when it's missing
# (so a fresh clone without private/config.mk still gets `make help`, etc.).
-include private/config.mk

# Defaults so the Makefile works before config.mk exists; config.mk overrides these.
REGION      ?= eu-central-1
RECORD_NAME ?= $(DOMAIN)

# Optional: `make <target> AWS_PROFILE=myprofile` to use a non-default AWS profile.
AWS     := aws $(if $(AWS_PROFILE),--profile $(AWS_PROFILE),)
ANSIBLE := ansible
CFN     := cloudformation

# Vault password handling. Default: prompt. Override, e.g.:
#   make site VAULT='--vault-password-file=$(HOME)/.db-vault-pass'
VAULT ?= --ask-vault-pass

.DEFAULT_GOAL := help
.PHONY: help validate backup-infra outputs site check tags issue-cert test-conn dev-env dbeaver dns dr-failover dr-teardown

help: ## Show this help
	@awk 'BEGIN{FS=":.*##"}/^[a-zA-Z0-9_-]+:.*##/{printf "  \033[36m%-13s\033[0m %s\n",$$1,$$2}' $(MAKEFILE_LIST)

# ── AWS / CloudFormation (need private/config.mk) ─────────────────────────────
validate: ## Validate the backup-infra template
	$(AWS) cloudformation validate-template --region $(REGION) \
	  --template-body file://$(CFN)/backup-infra.yaml >/dev/null && echo "template OK"

backup-infra: ## Deploy/update the persistent S3 + IAM + DNS stack
	@test -n "$(HOSTED_ZONE)$(PRIMARY_IP)$(RECORD_NAME)" || { echo "Set HOSTED_ZONE / PRIMARY_IP / RECORD_NAME in private/config.mk (cp config.example.mk private/config.mk)"; exit 1; }
	$(AWS) cloudformation deploy --region $(REGION) --stack-name db-backup-infra \
	  --template-file $(CFN)/backup-infra.yaml --capabilities CAPABILITY_NAMED_IAM \
	  --parameter-overrides HostedZoneId=$(HOSTED_ZONE) PrimaryIp=$(PRIMARY_IP) RecordName=$(RECORD_NAME)

outputs: ## Show backup-infra stack outputs (bucket, creds-secret ARN, endpoint)
	$(AWS) cloudformation describe-stacks --region $(REGION) --stack-name db-backup-infra \
	  --query 'Stacks[0].Outputs' --output table

# ── Ansible: VPS setup ────────────────────────────────────────────────────────
site: ## Full VPS setup — all phases (prompts for the vault password)
	cd $(ANSIBLE) && ansible-playbook playbooks/site.yml $(VAULT)

check: ## Dry-run the full playbook (--check, makes no changes)
	cd $(ANSIBLE) && ansible-playbook playbooks/site.yml $(VAULT) --check

tags: ## Run one phase: make tags T=db  (common|certs|db|projects|backups|monitoring|client-certs)
	@test -n "$(T)" || { echo "usage: make tags T=<tag>"; exit 1; }
	cd $(ANSIBLE) && ansible-playbook playbooks/site.yml $(VAULT) --tags $(T)

issue-cert: ## Issue an extra mTLS client cert: make issue-cert CN=somerole_app
	@test -n "$(CN)" || { echo "usage: make issue-cert CN=<role_name>"; exit 1; }
	cd $(ANSIBLE) && ansible-playbook playbooks/issue-client-cert.yml $(VAULT) -e cn=$(CN)

# ── Helpers ───────────────────────────────────────────────────────────────────
test-conn: ## Smoke-test a project's DB connection: make test-conn PROJECT=proj_scs
	@test -n "$(PROJECT)" || { echo "usage: make test-conn PROJECT=<name>"; exit 1; }
	AWS_REGION=$(REGION) ./scripts/test-db-connection.sh $(PROJECT)

dev-env: ## Local Next.js dev: writes private/dev/<p>/{client.*,.env.local}: make dev-env PROJECT=proj_scs
	@test -n "$(PROJECT)" || { echo "usage: make dev-env PROJECT=<name>"; exit 1; }
	AWS_REGION=$(REGION) ./scripts/dev-env.sh $(PROJECT) private/dev/$(PROJECT)

dbeaver: dev-env ## Same as dev-env + prints DBeaver fields. Steps: docs/dbeaver-setup.md
	@echo; echo "DBeaver fields printed above — full walkthrough: docs/dbeaver-setup.md"

dns: ## Show what the db record currently resolves to
	@test -n "$(RECORD_NAME)" || { echo "Set DOMAIN / RECORD_NAME in private/config.mk"; exit 1; }
	dig +short $(RECORD_NAME)

# ── Disaster recovery (reads private/dr.env; bills EC2 until torn down) ────────
dr-failover: ## Pilot-light failover to AWS (fill private/dr.env first)
	@test -f private/dr.env || { echo "create private/dr.env first — see the committed template"; exit 1; }
	. private/dr.env && ./scripts/dr-failover.sh

dr-teardown: ## Delete the DR stack after the primary recovers
	AWS_REGION=$(REGION) ./scripts/dr-teardown.sh
