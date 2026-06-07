#!/bin/sh
# Inner backup of Navidrome's SQLite DB (users, ratings, playlists,
# scrobbles, play counts).
#
# Runs from ops via cron (services/navidrome/cron.yaml). Same pattern as
# Authelia + Coolify backups — see docs/backups.md → "Inner backup pattern".
# Navidrome's own [Backup] config is intentionally NOT enabled; schedule
# and retention live in git, not in the app's toml.

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

HOST=root@$(ip_of navidrome)

SRC=/var/lib/navidrome/navidrome.db
DEST_DIR=/var/lib/navidrome/backups
LABEL=navidrome
KEEP=14

log_info "navidrome sqlite backup → $HOST:$DEST_DIR (keep last $KEEP)"
sqlite_backup_remote "$HOST" "$SRC" "$DEST_DIR" "$LABEL"
rotate_keep_last     "$HOST" "$DEST_DIR" "$LABEL-*.sqlite3" "$KEEP"
log_info "navidrome sqlite backup: done"
