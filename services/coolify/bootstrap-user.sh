#!/bin/bash
# Create the Coolify root user from BWS-stored credentials. Idempotent:
# if a user with the same email already exists, this is a no-op.
# Disables open registration after creating the first user.
#
# Pre-reqs: install.sh has run; BWS holds IEDORA_ADMIN_{NAME,EMAIL,PASSWORD}.

set -e

SCRIPT_DIR=$(cd "$(dirname "$0")" && pwd)
REPO_ROOT=${SCRIPT_DIR%/services/*}
[ -f "$REPO_ROOT/iac/.envrc" ] && . "$REPO_ROOT/iac/.envrc" >/dev/null 2>&1 || true

HOST=${COOLIFY_HOST:-192.168.50.200}

bws_get() {
  bws secret list --output json | jq -r --arg k "$1" '.[] | select(.key==$k) | .value'
}

echo "==> read admin creds from BWS"
ADMIN_NAME=$(bws_get IEDORA_ADMIN_NAME)
ADMIN_EMAIL=$(bws_get IEDORA_ADMIN_EMAIL)
ADMIN_PASSWORD=$(bws_get IEDORA_ADMIN_PASSWORD)
for v in "ADMIN_NAME:$ADMIN_NAME" "ADMIN_EMAIL:$ADMIN_EMAIL" "ADMIN_PASSWORD:$ADMIN_PASSWORD"; do
  [ -n "${v#*:}" ] || { echo "ERROR: IEDORA_${v%:*} missing in BWS"; exit 1; }
done

ESC_NAME=$(printf '%s' "$ADMIN_NAME" | sed "s/'/'\\\\''/g")
ESC_EMAIL=$(printf '%s' "$ADMIN_EMAIL" | sed "s/'/'\\\\''/g")
ESC_PASS=$(printf '%s' "$ADMIN_PASSWORD" | sed "s/'/'\\\\''/g")

TINKER_CODE=$(cat <<'PHP'
use App\Models\User;
use App\Models\Team;
use App\Models\InstanceSettings;
use Illuminate\Support\Facades\Hash;

$email = getenv('COOLIFY_BOOTSTRAP_EMAIL');
$name  = getenv('COOLIFY_BOOTSTRAP_NAME');
$pass  = getenv('COOLIFY_BOOTSTRAP_PASS');

$existing = User::firstWhere('email', $email);
if ($existing) {
    echo "USER_EXISTS=" . $existing->id . PHP_EOL;
    return;
}

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
$s = InstanceSettings::firstOrCreate([]);
$s->is_registration_enabled = false;
$s->save();
echo "USER_CREATED=" . $user->id . PHP_EOL;
PHP
)

echo "==> create root user if absent"
RESULT=$(ssh root@"$HOST" \
  "docker exec -e COOLIFY_BOOTSTRAP_NAME='$ESC_NAME' \
     -e COOLIFY_BOOTSTRAP_EMAIL='$ESC_EMAIL' \
     -e COOLIFY_BOOTSTRAP_PASS='$ESC_PASS' \
     coolify php artisan tinker --execute=$(printf '%q' "$TINKER_CODE")" \
  | grep -oE 'USER_(EXISTS|CREATED)=[0-9]+' | head -1)

case "$RESULT" in
  USER_EXISTS=*)  echo "    user already exists (id=${RESULT#USER_EXISTS=})" ;;
  USER_CREATED=*) echo "    user created (id=${RESULT#USER_CREATED=})" ;;
  *)              echo "ERROR: unexpected output: $RESULT"; exit 1 ;;
esac
