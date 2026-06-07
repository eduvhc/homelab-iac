<?php
// Tinker script: print how many days until $COOLIFY_TOKEN_ID expires.
// Output one line:  MISSING  | NEVER  | <signed int days>
//
// Run by services/coolify/ops/rotate-token.sh via:
//   docker exec -e COOLIFY_TOKEN_ID=... coolify php artisan tinker --execute=<this file>

$id = (int) getenv('COOLIFY_TOKEN_ID');
$t = App\Models\PersonalAccessToken::find($id);
if (!$t)              { echo "MISSING"; return; }
if (!$t->expires_at)  { echo "NEVER";   return; }
echo (int) floor(now()->diffInDays($t->expires_at, false));
