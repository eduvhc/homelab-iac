#!/bin/sh
# Install Coolify on the control-plane LXC + enable the API. Idempotent:
# skips install if Coolify is already present; enabling the API is a no-op
# on an already-enabled instance.
#
# Run from the ops LXC (needs ssh root access to $HOST). Doesn't touch BWS.

set -e

HOST=${COOLIFY_HOST:-192.168.50.200}

ssh -o StrictHostKeyChecking=accept-new root@"$HOST" 'true' >/dev/null

echo "==> install Coolify on $HOST (skipped if already installed)"
if ! ssh root@"$HOST" 'test -d /data/coolify/source'; then
  ssh root@"$HOST" 'export DEBIAN_FRONTEND=noninteractive
    apt-get update -qq
    apt-get install -y -qq curl ca-certificates
    curl -fsSL https://cdn.coollabs.io/coolify/install.sh -o /tmp/install.sh
    bash /tmp/install.sh' 2>&1 | tail -3
else
  echo "    already installed"
fi

echo "==> wait for Coolify API"
until ssh root@"$HOST" 'curl -fsS -m 3 http://localhost:8000/api/health 2>/dev/null' | grep -q OK; do
  sleep 3
done

echo "==> enable Coolify API (firstOrCreate the InstanceSettings row first —"
echo "    Coolify 4.1.x creates it lazily on first read, so ::first() returns"
echo "    null on a fresh install and silently no-ops the update)"
ssh root@"$HOST" 'docker exec coolify php artisan tinker --execute='"'"'App\Models\InstanceSettings::firstOrCreate([])->update(["is_api_enabled" => true]);'"'"'' >/dev/null

echo "==> install complete."
