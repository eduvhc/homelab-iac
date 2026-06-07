<?php
// Tinker script: mint a fresh "Open Tofu" personal access token for the
// user identified by $COOLIFY_USER_EMAIL. Always deletes any previous
// "Open Tofu" token first (no orphans). Emits the new id|plain on stdout
// for the shell wrapper to capture + write to sops.
//
// Run by services/coolify/ops/rotate-token.sh via:
//   docker exec -e COOLIFY_USER_EMAIL=... coolify php artisan tinker --execute=<this file>

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
    'abilities' => ['read', 'write', 'deploy'],
    'expires_at' => now()->addDays(30),
    'team_id' => 0,
]);
echo 'TOKEN=' . $tok->id . '|' . $plainTextToken . PHP_EOL;
