#!/bin/bash
# Rotate the Coolify API token used by the platform stack: delete the
# previous "Open Tofu" token, mint a fresh one (30-day TTL), save to BWS
# as COOLIFY_API_TOKEN.
#
# INTENTIONALLY NOT IDEMPOTENT: every call mints a new token by design.
# The cron at services/ops/iac.cron runs this every 25 days; apply.sh also
# calls it so a full apply guarantees a fresh token for the platform stack.
# If you re-run apply.sh many times in a row, you'll create many tokens —
# but the script always deletes the previous "Open Tofu"-named token first,
# so there are never orphans in Coolify.
#
# Pre-reqs: install.sh + bootstrap-user.sh have run; user with email
# IEDORA_ADMIN_EMAIL exists in Coolify.

set -e

SCRIPT_DIR=$(cd "$(dirname "$0")" && pwd)
REPO_ROOT=${SCRIPT_DIR%/services/*}
[ -f "$REPO_ROOT/iac/.envrc" ] && . "$REPO_ROOT/iac/.envrc" >/dev/null 2>&1 || true

HOST=${COOLIFY_HOST:-192.168.50.200}
PROJECT=${BWS_HOMELAB_PROJECT_ID:-e0f72a13-b559-44cc-a2a7-b44b01860f39}

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

ADMIN_EMAIL=$(bws_get IEDORA_ADMIN_EMAIL)
[ -n "$ADMIN_EMAIL" ] || { echo "ERROR: IEDORA_ADMIN_EMAIL missing in BWS"; exit 1; }
ESC_EMAIL=$(printf '%s' "$ADMIN_EMAIL" | sed "s/'/'\\\\''/g")

TINKER_CODE=$(cat <<'PHP'
use Illuminate\Support\Str;
use App\Models\User;

$user = User::firstWhere('email', getenv('COOLIFY_USER_EMAIL'));
if (!$user) { echo "ERROR=no_user"; return; }

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

echo "==> mint new API token (previous 'Open Tofu' token is deleted)"
TOKEN=$(ssh root@"$HOST" \
  "docker exec -e COOLIFY_USER_EMAIL='$ESC_EMAIL' \
     coolify php artisan tinker --execute=$(printf '%q' "$TINKER_CODE")" \
  | grep -oE 'TOKEN=[0-9]+\|[A-Za-z0-9]+' | sed 's/^TOKEN=//' | head -1)

[ -n "$TOKEN" ] || { echo "ERROR: failed to mint Coolify API token"; exit 1; }
echo "==> minted (${TOKEN%%|*}|…) — saving to BWS"

bws_put_or_update COOLIFY_API_TOKEN "$TOKEN" \
  "Coolify API token (read+write). Rotated by services/coolify/rotate-token.sh — expires after 30 days."

echo "==> rotated."
