#!/bin/sh
# Install Coolify on the control-plane LXC + enable the API. Idempotent:
# skips install if Coolify is already present; enabling the API is a no-op
# when already enabled.
#
# Run from the ops LXC (needs ssh root@$HOST). Doesn't touch secrets —
# the API token is minted later by bootstrap-user.sh + rotate-token.sh.

set -eu

SCRIPT_DIR=$(cd "$(dirname "$0")" && pwd)
# shellcheck disable=SC1091
. "$SCRIPT_DIR/../../tools/lib/common.sh"

require_cmd ssh

HOST=${COOLIFY_HOST:-192.168.50.200}

ssh -o StrictHostKeyChecking=accept-new root@"$HOST" 'true' >/dev/null

log_info "install Coolify on $HOST (skipped if already installed)"
if ! ssh root@"$HOST" 'test -d /data/coolify/source'; then
  ssh root@"$HOST" 'export DEBIAN_FRONTEND=noninteractive
    apt-get update -qq
    apt-get install -y -qq curl ca-certificates
    curl -fsSL https://cdn.coollabs.io/coolify/install.sh -o /tmp/install.sh
    bash /tmp/install.sh' 2>&1 | tail -3
else
  log_info "already installed"
fi

log_info "wait for Coolify API"
until ssh root@"$HOST" 'curl -fsS -m 3 http://localhost:8000/api/health 2>/dev/null' | grep -q OK; do
  sleep 3
done

# Coolify 4.1.x creates the InstanceSettings row lazily on first read, so
# `::first()` returns null on a brand-new install and the update silently
# no-ops. Use firstOrCreate to force-materialize the row, then update.
log_info "enable Coolify API (firstOrCreate row first)"
ssh root@"$HOST" 'docker exec coolify php artisan tinker --execute='"'"'App\Models\InstanceSettings::firstOrCreate([])->update(["is_api_enabled" => true]);'"'"'' >/dev/null

log_info "install complete."
