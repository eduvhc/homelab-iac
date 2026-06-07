<?php
// Tinker script: create or update the Coolify root user (id=0) from
// HOMELAB_ADMIN_{NAME,EMAIL,PASSWORD} env vars.
//
// Idempotent: lookup is by id=0 (the root user slot), not by email — so
// changing HOMELAB_ADMIN_EMAIL in sops still propagates without colliding
// on id=0 in the create branch. Email is lowercased to match Coolify's
// setEmailAttribute mutator.
//
// Coolify's User model marks `password` fillable but doesn't auto-hash
// on save (no `'hashed'` cast). We Hash::make() explicitly, and use
// Hash::check() so password rotations re-hash only when sops differs.
//
// Run by services/coolify/ops/bootstrap-user.sh via:
//   docker exec -e COOLIFY_BOOTSTRAP_* coolify php artisan tinker --execute=<this file>

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
