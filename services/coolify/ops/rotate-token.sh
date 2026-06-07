#!/bin/bash
# Ensure a fresh Coolify API token is in iac/secrets.sops.yaml. Idempotent:
# skips rotation if the stored token is valid for more than
# ROTATE_THRESHOLD_DAYS (default 7). Forces rotation with FORCE=1.
#
# Decision tree on each run:
#   • secrets.sops.yaml has no COOLIFY_API_TOKEN → mint
#   • DB has no row for that token id            → mint (stored value is stale)
#   • days_to_expiry > ROTATE_THRESHOLD_DAYS     → no-op (with status line)
#   • else                                        → mint
#
# The PHP runs in the coolify container (lives in target/*.php):
#   - target/check-token-expiry.php   read-only check (days_to_expiry)
#   - target/rotate-token.php         mint new token
#
# Pre-reqs: install.sh + bootstrap-user.sh have run; SOPS+age available.
# After rotation the script ALSO updates the in-memory $COOLIFY_API_TOKEN
# env var so the running session sees the new value. To persist for other
# sessions/CI: `git add iac/secrets.sops.yaml && git commit && git push`.

set -euo pipefail

SCRIPT_DIR=$(cd "$(dirname "$0")" && pwd)
# shellcheck disable=SC1091
. "$SCRIPT_DIR/../../../tools/lib/core/common.sh"
# shellcheck disable=SC1091
. "$SCRIPT_DIR/../../../tools/lib/secrets/sops.sh"

source_envrc
require_cmd sops jq ssh

HOST=${COOLIFY_HOST:-192.168.50.200}
THRESHOLD=${ROTATE_THRESHOLD_DAYS:-7}
TARGET_DIR="$SCRIPT_DIR/../target"

# tinker_exec PHP_FILE [docker -e flags...]   — run a target/*.php in the
# coolify container; returns its raw stdout. Strips the leading `<?php`
# tag (kept in files for editor highlighting) — tinker --execute expects
# bare PHP, not a full PHP file.
tinker_exec() {
  _php=$1; shift
  _code=$(sed -e '1{/^<?php/d}' "$_php")
  ssh root@"$HOST" \
    "docker exec $* coolify php artisan tinker --execute=$(printf '%q' "$_code")"
}

# ── Step 1: decide whether to rotate ─────────────────────────────────────────
REASON=""

if [ "${FORCE:-0}" = "1" ]; then
  REASON="FORCE=1"
else
  CURRENT=$(sops_get COOLIFY_API_TOKEN)
  if [ -z "$CURRENT" ]; then
    REASON="no COOLIFY_API_TOKEN in iac/secrets.sops.yaml"
  else
    TOKEN_ID=${CURRENT%%|*}
    # `|| true` so set -e + pipefail don't kill the apply on transient empty
    # output (Coolify booting, artisan warnings, etc.). The case below
    # treats empty as "couldn't determine → rotate defensively".
    DAYS_LEFT=$({ tinker_exec "$TARGET_DIR/check-token-expiry.php" \
      "-e COOLIFY_TOKEN_ID='$TOKEN_ID'" 2>/dev/null \
      | grep -E '^(-?[0-9]+|MISSING|NEVER)$' | tail -1 | tr -d '\r'; } || true)

    case "$DAYS_LEFT" in
      MISSING) REASON="stored token id=$TOKEN_ID doesn't exist in Coolify DB (stale)" ;;
      NEVER)   log_info "token id=$TOKEN_ID never expires — skipping rotation"; exit 0 ;;
      ''|*[!0-9-]*) REASON="couldn't determine expiry (got: '$DAYS_LEFT') — rotating defensively" ;;
      *)
        if [ "$DAYS_LEFT" -gt "$THRESHOLD" ]; then
          log_info "token id=$TOKEN_ID valid for $DAYS_LEFT more days (> $THRESHOLD) — no-op"
          exit 0
        fi
        REASON="token id=$TOKEN_ID expires in $DAYS_LEFT day(s) (≤ $THRESHOLD)" ;;
    esac
  fi
fi

# ── Step 2: rotate ───────────────────────────────────────────────────────────
log_info "rotating Coolify API token: $REASON"

ESC_EMAIL=$(printf '%s' "${HOMELAB_ADMIN_EMAIL:?}" | sed "s/'/'\\\\''/g")

TOKEN=$(tinker_exec "$TARGET_DIR/rotate-token.php" "-e COOLIFY_USER_EMAIL='$ESC_EMAIL'" \
  | grep -oE 'TOKEN=[0-9]+\|[A-Za-z0-9]+' | sed 's/^TOKEN=//' | head -1)

[ -n "$TOKEN" ] || die "failed to mint Coolify API token"

sops_set COOLIFY_API_TOKEN "$TOKEN"
export COOLIFY_API_TOKEN="$TOKEN"
export TF_VAR_coolify_api_token="$TOKEN"

log_info "rotated → new id=${TOKEN%%|*}, expires in 30 days"
log_info "  iac/secrets.sops.yaml updated. To persist: git add + commit + push."
