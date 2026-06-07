#!/bin/bash
# Create or update the Coolify root user from sops-managed credentials.
# Idempotent: creates user on first run, updates password on subsequent
# runs if HOMELAB_ADMIN_PASSWORD changed.
#
# Pre-reqs: install.sh has run.
# Inputs (all from iac/secrets.sops.yaml via source_envrc):
#   HOMELAB_ADMIN_NAME, HOMELAB_ADMIN_EMAIL — identifiers
#   HOMELAB_ADMIN_PASSWORD                  — admin password
#
# Coolify's User model marks `password` fillable but doesn't auto-hash on
# save (no `'hashed'` cast). We Hash::make() explicitly, and use
# Hash::check() to make password updates idempotent — only re-hash if the
# stored hash doesn't verify the current password. Email is lowercased by
# Coolify's setEmailAttribute mutator, so we lowercase before storing.
#
# Lookup is by id=0 (the root user slot), not by email — otherwise changing
# HOMELAB_ADMIN_EMAIL in sops would not propagate (firstWhere by new email
# returns null and the create branch would collide on id=0).

set -euo pipefail

SCRIPT_DIR=$(cd "$(dirname "$0")" && pwd)
# shellcheck disable=SC1091
. "$SCRIPT_DIR/../../tools/lib/core/common.sh"

source_envrc
require_cmd jq ssh

HOST=${COOLIFY_HOST:-192.168.50.200}

ADMIN_NAME=${HOMELAB_ADMIN_NAME:?must be in iac/secrets.sops.yaml}
ADMIN_EMAIL=${HOMELAB_ADMIN_EMAIL:?must be in iac/secrets.sops.yaml}
ADMIN_PASSWORD=${HOMELAB_ADMIN_PASSWORD:?must be in iac/secrets.sops.yaml}

ESC_NAME=$(printf '%s' "$ADMIN_NAME" | sed "s/'/'\\\\''/g")
ESC_EMAIL=$(printf '%s' "$ADMIN_EMAIL" | sed "s/'/'\\\\''/g")
ESC_PASS=$(printf '%s' "$ADMIN_PASSWORD" | sed "s/'/'\\\\''/g")

TINKER_CODE=$(cat <<'PHP'
use App\Models\User;
use App\Models\Team;
use App\Models\InstanceSettings;
use Illuminate\Support\Facades\Hash;

$email = strtolower(getenv('COOLIFY_BOOTSTRAP_EMAIL'));
$name  = getenv('COOLIFY_BOOTSTRAP_NAME');
$pass  = getenv('COOLIFY_BOOTSTRAP_PASS');

$existing = User::find(0);
if ($existing) {
    $changed = [];
    if ($existing->email !== $email) { $existing->email = $email; $changed[] = 'email'; }
    if ($existing->name  !== $name)  { $existing->name  = $name;  $changed[] = 'name'; }
    if (!Hash::check($pass, $existing->password)) {
        $existing->password = Hash::make($pass);
        $changed[] = 'password';
    }
    if ($changed) {
        $existing->save();
        echo "USER_UPDATED=" . $existing->id . ":" . implode(',', $changed) . PHP_EOL;
    } else {
        echo "USER_UNCHANGED=" . $existing->id . PHP_EOL;
    }
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

log_info "ensure root user + password matches sops"
result=$(ssh root@"$HOST" \
  "docker exec -e COOLIFY_BOOTSTRAP_NAME='$ESC_NAME' \
     -e COOLIFY_BOOTSTRAP_EMAIL='$ESC_EMAIL' \
     -e COOLIFY_BOOTSTRAP_PASS='$ESC_PASS' \
     coolify php artisan tinker --execute=$(printf '%q' "$TINKER_CODE")" \
  | grep -oE 'USER_(UNCHANGED|UPDATED|CREATED)=[0-9]+(:[a-z,]+)?' | head -1)

case "$result" in
  USER_UNCHANGED=*) log_info "user unchanged (id=${result#USER_UNCHANGED=})" ;;
  USER_UPDATED=*)   log_info "user updated (${result#USER_UPDATED=})" ;;
  USER_CREATED=*)   log_info "user created (id=${result#USER_CREATED=})" ;;
  *)                die "unexpected output: $result" ;;
esac
