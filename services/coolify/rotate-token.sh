#!/bin/bash
# Ensure a fresh Coolify API token is in BWS. Idempotent: skips rotation if
# the currently-stored token is valid for more than ROTATE_THRESHOLD_DAYS
# (default 7). Forces rotation with FORCE=1.
#
# Decision tree on each run:
#   • BWS has no COOLIFY_API_TOKEN          → mint
#   • DB has no row for that token id       → mint (BWS value is stale)
#   • days_to_expiry > ROTATE_THRESHOLD_DAYS → no-op (with status line)
#   • else                                   → mint
#
# Both tools/apply.sh AND the 25-day cron (services/ops/iac.cron) call this
# script unconditionally; the expiry check is what makes the rerun safe.
# Coolify tokens have a 30-day TTL, so the cron's 25-day cadence + the 7-day
# threshold means the token is refreshed with ~5 days of slack.
#
# Pre-reqs: install.sh + bootstrap-user.sh have run; user with email
# IEDORA_ADMIN_EMAIL exists in Coolify.

set -e

SCRIPT_DIR=$(cd "$(dirname "$0")" && pwd)
REPO_ROOT=${SCRIPT_DIR%/services/*}
[ -f "$REPO_ROOT/iac/.envrc" ] && . "$REPO_ROOT/iac/.envrc" >/dev/null 2>&1 || true

HOST=${COOLIFY_HOST:-192.168.50.200}
PROJECT=${BWS_HOMELAB_PROJECT_ID:-e0f72a13-b559-44cc-a2a7-b44b01860f39}
THRESHOLD=${ROTATE_THRESHOLD_DAYS:-7}

bws_get() {
  bws secret list --output json | jq -r --arg k "$1" '.[] | select(.key==$k) | .value'
}
bws_put_or_update() {
  existing_id=$(bws secret list --output json | jq -r --arg k "$1" '.[] | select(.key==$k) | .id')
  if [ -n "$existing_id" ] && [ "$existing_id" != "null" ]; then
    bws secret edit "$existing_id" --value "$2" >/dev/null
  else
    bws secret create "$1" "$2" "$PROJECT" --note "$3" >/dev/null
  fi
}

# ── Step 1: decide whether to rotate (each branch either exits 0 or falls
#           through with $REASON set). ───────────────────────────────────────
REASON=""

if [ "${FORCE:-0}" = "1" ]; then
  REASON="FORCE=1"
else
  CURRENT=$(bws_get COOLIFY_API_TOKEN)
  if [ -z "$CURRENT" ] || [ "$CURRENT" = "null" ]; then
    REASON="no COOLIFY_API_TOKEN in BWS"
  else
    # BWS value is "id|plainTextToken" — look up by id.
    TOKEN_ID=${CURRENT%%|*}
    DAYS_LEFT=$(ssh root@"$HOST" \
      "docker exec coolify php artisan tinker --execute='\
\$t = App\\\\Models\\\\PersonalAccessToken::find($TOKEN_ID); \
if (!\$t) { echo \"MISSING\"; return; } \
if (!\$t->expires_at) { echo \"NEVER\"; return; } \
echo (int) floor(now()->diffInDays(\$t->expires_at, false));'" 2>/dev/null \
      | grep -E '^(-?[0-9]+|MISSING|NEVER)$' | tail -1 | tr -d '\r')

    case "$DAYS_LEFT" in
      MISSING)
        REASON="BWS holds token id=$TOKEN_ID but it doesn't exist in Coolify DB (stale)" ;;
      NEVER)
        echo "==> token id=$TOKEN_ID never expires — skipping rotation"
        exit 0 ;;
      ''|*[!0-9-]*)
        REASON="couldn't determine expiry (got: '$DAYS_LEFT') — rotating defensively" ;;
      *)
        if [ "$DAYS_LEFT" -gt "$THRESHOLD" ]; then
          echo "==> token id=$TOKEN_ID valid for $DAYS_LEFT more days (> $THRESHOLD) — no-op"
          exit 0
        fi
        REASON="token id=$TOKEN_ID expires in $DAYS_LEFT day(s) (≤ $THRESHOLD)" ;;
    esac
  fi
fi

# ── Step 2: rotate ────────────────────────────────────────────────────────────
echo "==> rotating Coolify API token: $REASON"

ADMIN_EMAIL=$(bws_get IEDORA_ADMIN_EMAIL)
[ -n "$ADMIN_EMAIL" ] || { echo "ERROR: IEDORA_ADMIN_EMAIL missing in BWS"; exit 1; }
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
    'abilities' => ['read', 'write'],
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

[ -n "$TOKEN" ] || { echo "ERROR: failed to mint Coolify API token"; exit 1; }

bws_put_or_update COOLIFY_API_TOKEN "$TOKEN" \
  "Coolify API token (read+write). Managed by services/coolify/rotate-token.sh — 30-day TTL, refreshed when <7d remain."

echo "==> rotated → new id=${TOKEN%%|*}, expires in 30 days"
