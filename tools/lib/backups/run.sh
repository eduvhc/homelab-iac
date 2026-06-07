#!/bin/sh
# Backup driver — dispatched from cron by assemble-crons. Translates a
# flat set of CLI flags (emitted by tools/lib/assemble-crons from each
# services/<svc>/backups.yaml entry) into a call into the appropriate
# engine helper, followed by retention rotation.
#
# Usage (always invoked by cron, not by hand):
#   run.sh --engine postgres --name NAME --host SVC --dest-dir DIR \
#          --retention-keep-last N --container C --user U --database D
#   run.sh --engine sqlite   --name NAME --host SVC --dest-dir DIR \
#          --retention-keep-last N --src /path/to/file.db
#
# Engine-specific flags after the common ones — see the schema header in
# services/coolify/backups.yaml.
#
# Output convention: dumps land at  DEST_DIR/<NAME>-<UTC-ts>.<ext>
# where <ext> is engine-specific (postgres→dmp, sqlite→sqlite3).

set -eu

SCRIPT_DIR=$(cd "$(dirname "$0")" && pwd)
REPO_ROOT=${SCRIPT_DIR%/tools/*}
export REPO_ROOT
# shellcheck disable=SC1091
. "$REPO_ROOT/tools/lib/core/common.sh"
# shellcheck disable=SC1091
. "$REPO_ROOT/tools/lib/infra/ips.sh"
# shellcheck disable=SC1091
. "$REPO_ROOT/tools/lib/backups/retention.sh"

# ── Parse common + engine-specific flags ────────────────────────────────────
engine=''; name=''; host=''; dest_dir=''; retention_keep_last=''
container=''; user=''; database=''; src=''

while [ $# -gt 0 ]; do
  case $1 in
    --engine)              engine=$2;              shift 2 ;;
    --name)                name=$2;                shift 2 ;;
    --host)                host=$2;                shift 2 ;;
    --dest-dir)            dest_dir=$2;            shift 2 ;;
    --retention-keep-last) retention_keep_last=$2; shift 2 ;;
    --container)           container=$2;           shift 2 ;;
    --user)                user=$2;                shift 2 ;;
    --database)            database=$2;            shift 2 ;;
    --src)                 src=$2;                 shift 2 ;;
    *) die "run.sh: unknown flag '$1'" ;;
  esac
done

[ -n "$engine" ]              || die "run.sh: --engine is required"
[ -n "$name" ]                || die "run.sh: --name is required"
[ -n "$host" ]                || die "run.sh: --host is required"
[ -n "$dest_dir" ]            || die "run.sh: --dest-dir is required"
[ -n "$retention_keep_last" ] || die "run.sh: --retention-keep-last is required"

HOST=root@$(ip_of "$host")

# ── Dispatch by engine ──────────────────────────────────────────────────────
case $engine in
  postgres)
    # shellcheck disable=SC1091
    . "$REPO_ROOT/tools/lib/backups/postgres.sh"
    for _req in container user database; do
      eval "[ -n \"\${$_req:-}\" ]" || die "run.sh: --$_req is required for engine=postgres"
    done
    log_info "backup: postgres → $HOST:$dest_dir (keep_last=$retention_keep_last)"
    pg_dump_in_container "$HOST" "$container" "$user" "$database" "$dest_dir" "$name"
    rotate_keep_last     "$HOST" "$dest_dir" "$name-*.dmp" "$retention_keep_last"
    ;;
  sqlite)
    # shellcheck disable=SC1091
    . "$REPO_ROOT/tools/lib/backups/sqlite.sh"
    [ -n "${src:-}" ] || die "run.sh: --src is required for engine=sqlite"
    log_info "backup: sqlite → $HOST:$dest_dir (keep_last=$retention_keep_last)"
    sqlite_backup_remote "$HOST" "$src" "$dest_dir" "$name"
    rotate_keep_last     "$HOST" "$dest_dir" "$name-*.sqlite3" "$retention_keep_last"
    ;;
  *)
    die "run.sh: unknown engine '$engine' (supported: postgres, sqlite)"
    ;;
esac

log_info "backup $name: done"
