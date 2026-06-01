# Template for private/config.mk — your real IDs, consumed by the root Makefile.
# Copy and fill in; the real file is gitignored (lives in the private overlay):
#   cp config.example.mk private/config.mk
REGION        := eu-central-1
DOMAIN        := db.example.com
RECORD_NAME   := db.example.com
PRIMARY_IP    := CHANGE_ME
HOSTED_ZONE   := CHANGE_ME
ACCOUNT_ID    := CHANGE_ME
BACKUP_BUCKET := CHANGE_ME
