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
# Pre-reqs: install.sh + bootstrap-user.sh have run; SOPS+age available.
# After rotation the script ALSO updates the in-memory $COOLIFY_API_TOKEN
# env var so the running session sees the new value. To persist for other
# sessions/CI: `git add iac/secrets.sops.yaml && git commit && git push`.

set -euo pipefail

SCRIPT_DIR=$(cd "$(dirname "$0")" && pwd)
# shellcheck disable=SC1091
. "$SCRIPT_DIR/../../tools/lib/common.sh"
# shellcheck disable=SC1091
. "$SCRIPT_DIR/../../tools/lib/sops.sh"

source_envrc
require_cmd sops jq ssh

HOST=${COOLIFY_HOST:-192.168.50.200}
THRESHOLD=${ROTATE_THRESHOLD_DAYS:-7}

# ── Step 1: decide whether to rotate ─────────────────────────────────────────
REASON=""

if [ "${FORCE:-0}" = "1" ]; then
  REASON="FORCE=1"
else
  CURRENT=$(sops_get COOLIFY_API_TOKEN)
  if [ -z "$CURRENT" ]; then
    REASON="no COOLIFY_API_TOKEN in iac/secrets.sops.yaml"
  else
    # Stored value is "id|plainTextToken" — look up by id.
    TOKEN_ID=${CURRENT%%|*}
    # The tinker pipeline can return empty when Coolify is still booting,
    # when artisan prints non-matching warnings, or when grep finds nothing
    # — `|| true` keeps `set -e + pipefail` from killing the whole apply.
    # The case below treats empty as "couldn't determine → rotate defensively".
    DAYS_LEFT=$({ ssh root@"$HOST" \
      "docker exec coolify php artisan tinker --execute='\
\$t = App\\\\Models\\\\PersonalAccessToken::find($TOKEN_ID); \
if (!\$t) { echo \"MISSING\"; return; } \
if (!\$t->expires_at) { echo \"NEVER\"; return; } \
echo (int) floor(now()->diffInDays(\$t->expires_at, false));'" 2>/dev/null \
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

ADMIN_EMAIL=${HOMELAB_ADMIN_EMAIL:?must be in iac/secrets.sops.yaml}
ESC_EMAIL=$(printf '%s' "$ADMIN_EMAIL" | sed "s/'/'\\\\''/g")

TINKER_CODE=$(cat <<'PHP'
use Illuminate\Support\Str;
use App\Models\User;

$user = User::firstWhere('email', getenv('COOLIFY_USER_EMAIL'));
if (!$user) { echo "ERROR=no_user"; return; }

// Always delete the previous "Open Tofu" token first → no orphans.
$user->tokens()->where('name', 'Open Tofu')->delete();
$plain = Str::random(40);
$plainTextToken = $plain . hash('crc32b', $plain);
$tok = $user->tokens()->create([
    'name' => 'Open Tofu',
    'token' => hash('sha256', $plainTextToken),
    'abilities' => ['read', 'write', 'deploy'],
    'expires_at' => now()->addDays(30),
    'team_id' => 0,
]);
echo 'TOKEN=' . $tok->id . '|' . $plainTextToken . PHP_EOL;
PHP
)

TOKEN=$(ssh root@"$HOST" \
  "docker exec -e COOLIFY_USER_EMAIL='$ESC_EMAIL' \
     coolify php artisan tinker --execute=$(printf '%q' "$TINKER_CODE")" \
  | grep -oE 'TOKEN=[0-9]+\|[A-Za-z0-9]+' | sed 's/^TOKEN=//' | head -1)

[ -n "$TOKEN" ] || die "failed to mint Coolify API token"

sops_set COOLIFY_API_TOKEN "$TOKEN"
export COOLIFY_API_TOKEN="$TOKEN"
export TF_VAR_coolify_api_token="$TOKEN"

log_info "rotated → new id=${TOKEN%%|*}, expires in 30 days"
log_info "  iac/secrets.sops.yaml updated. To persist: git add + commit + push."
