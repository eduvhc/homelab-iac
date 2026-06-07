#!/bin/sh
# Inner backup of AdGuard Home's stats SQLite DB (DNS query history,
# blocked counts, top domains — months of analytics).
#
# Only stats.db is backed up:
#   - sessions.db   ephemeral (login sessions, invalidated on restart)
#   - filters/      re-downloaded from upstream on schedule
#   - leases.db     would matter if DHCP was on; currently not used
#   - stats.db      historical analytics, NOT trivially reproducible
#
# AdGuardHome.yaml is already declarative (rendered by sync.sh from
# the template in this repo) and captured by vzdump, so no inner dump
# is needed for the config.
#
# Runs from ops via cron (services/adguard/cron.yaml). Same pattern as
# Authelia + Navidrome — see docs/backups.md → "Inner backup pattern".

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

HOST=root@$(ip_of adguard)

SRC=/opt/AdGuardHome/data/stats.db
DEST_DIR=/var/lib/adguard/backups
LABEL=adguard-stats
KEEP=14

log_info "adguard sqlite backup → $HOST:$DEST_DIR (keep last $KEEP)"
sqlite_backup_remote "$HOST" "$SRC" "$DEST_DIR" "$LABEL"
rotate_keep_last     "$HOST" "$DEST_DIR" "$LABEL-*.sqlite3" "$KEEP"
log_info "adguard sqlite backup: done"
