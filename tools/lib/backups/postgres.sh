# shellcheck shell=sh
# Postgres backup helper — pg_dump inside a remote container, write to
# the remote host's filesystem so vzdump captures it.
#
# Source from a per-service backup script:
#   . "$REPO_ROOT/tools/lib/backups/postgres.sh"
#   pg_dump_in_container \
#     "$HOST" coolify-db coolify coolify \
#     /data/coolify/backups/source coolify-source

# pg_dump_in_container HOST CONTAINER PG_USER DB DEST_DIR LABEL
#   Runs `pg_dump --format=custom` inside CONTAINER on HOST as PG_USER
#   for database DB, writing the result to:
#     DEST_DIR/<LABEL>-<UTC-timestamp>.dmp
#
#   The custom format is binary, compressed, and restored with pg_restore.
#   Same format Coolify itself uses for its internal backups.
#
#   Idempotent on its own (every run creates a new timestamped file);
#   callers pair this with rotate_keep_last from retention.sh to bound
#   disk usage.
#
#   Exits non-zero if pg_dump fails. The dump file is only kept if
#   pg_dump exits 0 — a partial file is deleted before returning, to
#   avoid retention preserving corrupt dumps.
pg_dump_in_container() {
  _host=$1; _container=$2; _user=$3; _db=$4; _dest_dir=$5; _label=$6

  for _arg in "$_host" "$_container" "$_user" "$_db" "$_dest_dir" "$_label"; do
    [ -n "$_arg" ] || { echo "pg_dump_in_container: missing required argument" >&2; return 1; }
  done

  # UTC timestamp matches vzdump's filename convention (YYYY_MM_DD-HH_MM_SS),
  # so operators reading both side-by-side see the same format.
  _ts=$(date -u +%Y_%m_%d-%H_%M_%S)
  _file="$_dest_dir/$_label-$_ts.dmp"

  # mkdir -p with explicit perms — 700 because dumps contain raw DB
  # contents (secrets, hashes). chown root so only root reads them.
  ssh "$_host" "mkdir -p '$_dest_dir' && chmod 700 '$_dest_dir' && chown root:root '$_dest_dir'"

  # Run pg_dump inside the container, redirect into the file on the host.
  # `docker exec -i` streams stdout cleanly; we pipe through `tee` on the
  # remote into the dest file, then check the exit status of pg_dump via
  # PIPESTATUS-equivalent (we ssh with `set -o pipefail` enabled).
  #
  # If pg_dump fails, delete the partial file so retention doesn't see
  # a corrupt dump as "the latest good one".
  if ssh "$_host" "set -o pipefail 2>/dev/null; docker exec -i '$_container' pg_dump --format=custom --no-acl --no-owner --username='$_user' '$_db' > '$_file'"; then
    # Sanity: pg_dump can exit 0 with an empty file in edge cases. Guard.
    _size=$(ssh "$_host" "stat -c%s '$_file' 2>/dev/null || echo 0")
    if [ "$_size" -lt 100 ]; then
      ssh "$_host" "rm -f '$_file'"
      echo "pg_dump_in_container: dump file is suspiciously small (${_size}B) — deleted" >&2
      return 1
    fi
    echo "pg_dump: $_label → $_file (${_size}B)"
    return 0
  else
    ssh "$_host" "rm -f '$_file'"
    echo "pg_dump_in_container: pg_dump failed; partial file removed" >&2
    return 1
  fi
}
