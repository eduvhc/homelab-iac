#!/bin/sh
# Inner backup of Authelia's SQLite DB (TOTP enrollments, session
# storage, identity-verification cookies, audit log).
#
# Why inner: a vzdump snapshot of an active SQLite-WAL database can
# be filesystem-consistent yet still need WAL recovery on open. The
# SQLite Backup API (.backup dot-command) produces a single consistent
# file safe to restore anywhere. TOTP secrets in particular MUST NOT
# come back corrupt — 2FA enrollment is a manual user action.
#
# Runs from ops via cron (services/gateway/cron.yaml).

set -eu

SCRIPT_DIR=$(cd "$(dirname "$0")" && pwd)
REPO_ROOT=${SCRIPT_DIR%/services/*}
export REPO_ROOT
# shellcheck disable=SC1091
. "$REPO_ROOT/tools/lib/common.sh"
# shellcheck disable=SC1091
. "$REPO_ROOT/tools/lib/ip-from-yaml.sh"
# shellcheck disable=SC1091
. "$REPO_ROOT/tools/backups/lib/sqlite.sh"
# shellcheck disable=SC1091
. "$REPO_ROOT/tools/backups/lib/retention.sh"

HOST=root@$(ip_of gateway)

SRC=/var/lib/authelia/db.sqlite3
DEST_DIR=/var/lib/authelia/backups
LABEL=authelia
KEEP=14

log_info "authelia sqlite backup → $HOST:$DEST_DIR (keep last $KEEP)"
sqlite_backup_remote "$HOST" "$SRC" "$DEST_DIR" "$LABEL"
rotate_keep_last     "$HOST" "$DEST_DIR" "$LABEL-*.sqlite3" "$KEEP"
log_info "authelia sqlite backup: done"
