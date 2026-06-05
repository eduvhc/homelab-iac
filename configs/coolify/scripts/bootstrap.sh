#!/bin/sh
# Idempotent bootstrap of a Coolify control plane LXC.
#
# Run from an LXC that has: bws CLI + ssh root access to $HOST.
# Sources IEDORA_ADMIN_NAME/EMAIL/PASSWORD from BWS, then:
#   1. installs Coolify (if not already installed)
#   2. creates root user in DB (if no users yet)
#   3. mints an "Open Tofu" API token (rotated each run)
#   4. saves the token back into BWS as COOLIFY_API_TOKEN
#
# Pre-reqs in BWS project homelab:
#   IEDORA_ADMIN_NAME, IEDORA_ADMIN_EMAIL, IEDORA_ADMIN_PASSWORD

set -e

# Auto-source iac/.envrc so bws CLI has BW_ACCESS_TOKEN etc when invoked
# from anywhere. Path is repo-relative.
SCRIPT_DIR=$(cd "$(dirname "$0")" && pwd)
REPO_ROOT=${SCRIPT_DIR%/configs/*}
if [ -f "$REPO_ROOT/iac/.envrc" ]; then
  . "$REPO_ROOT/iac/.envrc" >/dev/null 2>&1 || true
fi
HOST=${COOLIFY_HOST:-192.168.50.200}
PROJECT=${BWS_HOMELAB_PROJECT_ID:-e0f72a13-b559-44cc-a2a7-b44b01860f39}

bws_get() {
  bws secret list --output json | jq -r --arg k "$1" '.[] | select(.key==$k) | .value'
}
bws_put_or_update() {
  # args: key value note
  existing_id=$(bws secret list --output json | jq -r --arg k "$1" '.[] | select(.key==$k) | .id')
  if [ -n "$existing_id" ] && [ "$existing_id" != "null" ]; then
    bws secret edit "$existing_id" --value "$2" >/dev/null
  else
    bws secret create "$1" "$2" "$PROJECT" --note "$3" >/dev/null
  fi
}

echo "==> reading admin creds from BWS"
ADMIN_NAME=$(bws_get IEDORA_ADMIN_NAME)
ADMIN_EMAIL=$(bws_get IEDORA_ADMIN_EMAIL)
ADMIN_PASSWORD=$(bws_get IEDORA_ADMIN_PASSWORD)
for v in "ADMIN_NAME:$ADMIN_NAME" "ADMIN_EMAIL:$ADMIN_EMAIL" "ADMIN_PASSWORD:$ADMIN_PASSWORD"; do
  [ -n "${v#*:}" ] || { echo "ERROR: COOLIFY_${v%:*} missing in BWS"; exit 1; }
done

echo "==> installing Coolify on $HOST (skipped if already installed)"
ssh -o StrictHostKeyChecking=accept-new root@"$HOST" 'true' >/dev/null
if ! ssh root@"$HOST" 'test -d /data/coolify/source'; then
  ssh root@"$HOST" 'export DEBIAN_FRONTEND=noninteractive
    apt-get update -qq
    apt-get install -y -qq curl ca-certificates
    curl -fsSL https://cdn.coollabs.io/coolify/install.sh -o /tmp/install.sh
    bash /tmp/install.sh' 2>&1 | tail -3
fi

echo "==> waiting for Coolify API"
until ssh root@"$HOST" 'curl -fsS -m 3 http://localhost:8000/api/health 2>/dev/null' | grep -q OK; do
  sleep 3
done

echo "==> creating root user (if absent) and minting token"
ESC_NAME=$(printf '%s' "$ADMIN_NAME" | sed "s/'/'\\\\''/g")
ESC_EMAIL=$(printf '%s' "$ADMIN_EMAIL" | sed "s/'/'\\\\''/g")
ESC_PASS=$(printf '%s' "$ADMIN_PASSWORD" | sed "s/'/'\\\\''/g")

TINKER_CODE=$(cat <<'PHP'
use Illuminate\Support\Str;
use App\Models\User;
use App\Models\Team;
use App\Models\InstanceSettings;
use Illuminate\Support\Facades\Hash;

$email = getenv('COOLIFY_BOOTSTRAP_EMAIL');
$name  = getenv('COOLIFY_BOOTSTRAP_NAME');
$pass  = getenv('COOLIFY_BOOTSTRAP_PASS');

$user = User::firstWhere('email', $email);
if (!$user) {
    $user = (new User)->forceFill([
        'id' => 0,
        'name' => $name,
        'email' => $email,
        'password' => Hash::make($pass),
    ]);
    $user->save();
    $team = Team::find(0);
    if ($team && !$user->teams()->where('team_id', 0)->exists()) {
        $user->teams()->attach($team, ['role' => 'owner']);
    }
    $s = InstanceSettings::first();
    if ($s) { $s->is_registration_enabled = false; $s->save(); }
}

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
  "docker exec -e COOLIFY_BOOTSTRAP_NAME='$ESC_NAME' \
     -e COOLIFY_BOOTSTRAP_EMAIL='$ESC_EMAIL' \
     -e COOLIFY_BOOTSTRAP_PASS='$ESC_PASS' \
     coolify php artisan tinker --execute=$(printf '%q' "$TINKER_CODE")" \
  | grep -oE 'TOKEN=[0-9]+\|[A-Za-z0-9]+' | sed 's/^TOKEN=//' | head -1)

[ -n "$TOKEN" ] || { echo "ERROR: failed to mint Coolify API token"; exit 1; }
echo "==> minted token (${TOKEN%%|*}|...)"

echo "==> saving COOLIFY_API_TOKEN to BWS"
bws_put_or_update COOLIFY_API_TOKEN "$TOKEN" "Coolify API token (read+write), minted by configs/coolify/scripts/bootstrap.sh - rotates each run; expires after 30 days."

echo "==> done."
