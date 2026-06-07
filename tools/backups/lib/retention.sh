# shellcheck shell=sh
# Backup retention helpers — keep the N most recent files, drop the rest.
# Pure POSIX, runs over SSH on the target host.
#
# Source from a per-service backup script:
#   . "$REPO_ROOT/tools/backups/lib/retention.sh"
#   rotate_keep_last "$HOST" /data/coolify/backups/source 'coolify-source-*.dmp' 14

# rotate_keep_last HOST DIR PATTERN KEEP
#   Lists files in DIR matching PATTERN on HOST, sorted newest first by
#   mtime, and deletes everything past KEEP. PATTERN is a shell glob (not
#   regex) evaluated on the remote host by sh.
#
#   `ls -t` is used (not find -printf) for POSIX portability across
#   Debian/Alpine. Empty matches are a no-op.
rotate_keep_last() {
  _host=$1; _dir=$2; _pattern=$3; _keep=$4
  [ -n "$_host" ]    || { echo "rotate_keep_last: HOST is empty"    >&2; return 1; }
  [ -n "$_dir" ]     || { echo "rotate_keep_last: DIR is empty"     >&2; return 1; }
  [ -n "$_pattern" ] || { echo "rotate_keep_last: PATTERN is empty" >&2; return 1; }
  case $_keep in
    ''|*[!0-9]*) echo "rotate_keep_last: KEEP must be a positive integer" >&2; return 1 ;;
  esac

  # The remote pipeline: cd into the dir, list matching files newest-first,
  # tail past the keep window, xargs rm. `2>/dev/null` on ls suppresses the
  # "no matches" message when the dir is fresh.
  ssh "$_host" "cd '$_dir' 2>/dev/null && ls -t $_pattern 2>/dev/null | tail -n +$((_keep + 1)) | xargs -r rm -f --"
}
