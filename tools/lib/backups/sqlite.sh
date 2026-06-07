# shellcheck shell=sh
# SQLite backup helper — online backup via the SQLite Backup API, writing
# to the remote host's filesystem so vzdump captures it.
#
# Source from a per-service backup script:
#   . "$REPO_ROOT/tools/lib/backups/sqlite.sh"
#   sqlite_backup_remote \
#     "$HOST" /var/lib/authelia/db.sqlite3 \
#     /var/lib/authelia/backups authelia
#
# Why the .backup dot-command (and not cp): SQLite in WAL mode keeps
# uncommitted pages in a -wal sidecar file. `cp` of the main file misses
# them; `cp` of both files races with active writers. The .backup
# dot-command uses the SQLite Backup API: it takes a series of small
# locks, copies pages incrementally, retries pages modified mid-backup,
# and produces a single consistent file. Safe with a running writer.

# sqlite_backup_remote HOST SRC_FILE DEST_DIR LABEL
#   Runs `sqlite3 SRC ".backup DEST_DIR/LABEL-<UTC-ts>.sqlite3"` on HOST.
#   Pre-req: `sqlite3` CLI must be installed on HOST (add it to the
#   service's bootstrap.sh).
#
#   Idempotent on its own (every run creates a new timestamped file);
#   callers pair this with rotate_keep_last from retention.sh.
#
#   Exits non-zero if .backup fails; partial file is deleted to avoid
#   retention preserving a corrupt dump as the latest good one.
sqlite_backup_remote() {
  _host=$1; _src=$2; _dest_dir=$3; _label=$4

  for _arg in "$_host" "$_src" "$_dest_dir" "$_label"; do
    [ -n "$_arg" ] || { echo "sqlite_backup_remote: missing required argument" >&2; return 1; }
  done

  _ts=$(date -u +%Y_%m_%d-%H_%M_%S)
  _file="$_dest_dir/$_label-$_ts.sqlite3"

  # Create dest dir as root:root, 700 — dumps may contain session
  # tokens / TOTP secrets / etc.
  ssh "$_host" "mkdir -p '$_dest_dir' && chmod 700 '$_dest_dir' && chown root:root '$_dest_dir'"

  if ssh "$_host" "sqlite3 '$_src' \".backup '$_file'\""; then
    _size=$(ssh "$_host" "stat -c%s '$_file' 2>/dev/null || echo 0")
    if [ "$_size" -lt 100 ]; then
      ssh "$_host" "rm -f '$_file'"
      echo "sqlite_backup_remote: dump file is suspiciously small (${_size}B) — deleted" >&2
      return 1
    fi
    # Sanity: verify the dump opens as a valid SQLite DB before we trust it.
    if ! ssh "$_host" "sqlite3 '$_file' 'PRAGMA integrity_check;' 2>/dev/null | grep -q '^ok$'"; then
      ssh "$_host" "rm -f '$_file'"
      echo "sqlite_backup_remote: integrity_check failed on $_file — deleted" >&2
      return 1
    fi
    echo "sqlite backup: $_label → $_file (${_size}B, integrity ok)"
    return 0
  else
    ssh "$_host" "rm -f '$_file'"
    echo "sqlite_backup_remote: .backup command failed; partial file removed" >&2
    return 1
  fi
}
