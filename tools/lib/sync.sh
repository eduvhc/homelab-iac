# shellcheck shell=sh
# Shared helpers for services/*/sync.sh.
#
# Usage:
#   . "$REPO_ROOT/tools/lib/sync.sh"
#   needs_push <local-file> <remote-path>   # returns 0 if remote differs
#
# Pre-reqs:
#   - HOST var set to "root@<ip>" before calling needs_push
#   - sha256sum available on both sides

# needs_push: idempotency check via sha256 comparison. Returns 0 (true) if
# the remote file is missing or has different content, so the caller knows
# whether scp + restart is actually needed.
needs_push() {
  _local=$(sha256sum "$1" | cut -d' ' -f1)
  _remote=$(ssh "$HOST" "sha256sum '$2' 2>/dev/null | cut -d' ' -f1" || echo "")
  [ "$_local" != "$_remote" ]
}

# atomic_push: scp to <remote>.tmp then mv to <remote>. mv on the same
# filesystem is atomic at the inode level, so readers (e.g. Authelia's
# file watcher) never observe a truncated mid-scp state. Use instead of
# raw scp when a watcher or live reader may read the file at any moment.
atomic_push() {
  scp -q "$1" "$HOST:$2.tmp"
  ssh "$HOST" "mv '$2.tmp' '$2'"
}
