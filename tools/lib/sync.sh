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
