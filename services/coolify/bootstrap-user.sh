#!/bin/bash
# Create the Coolify root user from secrets-managed credentials. Idempotent:
# if a user with the same email already exists, this is a no-op.
# Disables open registration after creating the first user.
#
# Pre-reqs: install.sh has run.
# Inputs (all from iac/secrets.sops.yaml via source_envrc):
#   IEDORA_ADMIN_NAME, IEDORA_ADMIN_EMAIL — identifiers
#   IEDORA_ADMIN_PASSWORD — bootstrap password

set -euo pipefail

SCRIPT_DIR=$(cd "$(dirname "$0")" && pwd)
# shellcheck disable=SC1091
. "$SCRIPT_DIR/../../tools/lib/common.sh"

source_envrc
require_cmd jq ssh

HOST=${COOLIFY_HOST:-192.168.50.200}

ADMIN_NAME=${IEDORA_ADMIN_NAME:?must be in iac/secrets.sops.yaml}
ADMIN_EMAIL=${IEDORA_ADMIN_EMAIL:?must be in iac/secrets.sops.yaml}
ADMIN_PASSWORD=${IEDORA_ADMIN_PASSWORD:?must be in iac/secrets.sops.yaml}

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
    'id' => 0, 'name' => $name, 'email' => $email,
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

log_info "create root user if absent"
result=$(ssh root@"$HOST" \
  "docker exec -e COOLIFY_BOOTSTRAP_NAME='$ESC_NAME' \
     -e COOLIFY_BOOTSTRAP_EMAIL='$ESC_EMAIL' \
     -e COOLIFY_BOOTSTRAP_PASS='$ESC_PASS' \
     coolify php artisan tinker --execute=$(printf '%q' "$TINKER_CODE")" \
  | grep -oE 'USER_(EXISTS|CREATED)=[0-9]+' | head -1)

case "$result" in
  USER_EXISTS=*)  log_info "user already exists (id=${result#USER_EXISTS=})" ;;
  USER_CREATED=*) log_info "user created (id=${result#USER_CREATED=})" ;;
  *)              die "unexpected output: $result" ;;
esac
