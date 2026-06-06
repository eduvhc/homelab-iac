#!/bin/sh
# Rebuild the entire iedora homelab from infra layer up.
#
# Sequence (each phase is idempotent — re-running this is safe):
#   1. Apply iac/stacks/infra (creates 4 LXCs + CF tunnel + DNS)
#   2. Wait for LXCs to be SSH-reachable
#   3. Bootstrap each service LXC (installs binaries + creates secrets)
#   4. Install cloudflared on the Coolify LXC with the tunnel token
#   5. Bootstrap Coolify (installs Coolify + creates root user + mints API token to BWS)
#   6. Apply iac/stacks/platform (registers coolify-runner-01 in Coolify)
#
# Pre-reqs:
#   - All BWS secrets seeded (see tools/seed-bws.sh)
#   - iac/.envrc populated with BW_ORGANIZATION_ID and /root/.bws-token present
#   - Ops LXC has /root/.ssh/id_ed25519 (key already trusted by PVE root)
#
# LXC IPs are NEVER hardcoded here. After Phase 1, tools/lib/lxc-ips.sh
# reads tofu output and exports IP_ADGUARD / IP_GATEWAY / IP_COOLIFY /
# IP_RUNNER / ALL_LXC_IPS. Change IPs by editing iac/stacks/infra/locals.tf.

set -e

export PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin

SCRIPT_DIR=$(cd "$(dirname "$0")" && pwd)
REPO_ROOT=${SCRIPT_DIR%/tools}
# shellcheck disable=SC1091
. "$REPO_ROOT/iac/.envrc"

INFRA_DIR="$REPO_ROOT/iac/stacks/infra"
PLATFORM_DIR="$REPO_ROOT/iac/stacks/platform"

step() { printf '\n\033[1;34m[%s]\033[0m %s\n' "$1" "$2"; }
sub()  { printf '  → %s\n' "$1"; }

wait_ssh() {
  # args: ip [timeout_seconds]
  ip=$1; max=${2:-120}; i=0
  while [ $i -lt "$max" ]; do
    if ssh -o BatchMode=yes -o ConnectTimeout=2 -o StrictHostKeyChecking=accept-new \
       root@"$ip" true 2>/dev/null; then
      return 0
    fi
    sleep 2; i=$((i + 2))
  done
  echo "ERROR: $ip not SSH-reachable after ${max}s"; return 1
}

# ───────────────────────────────────────────────────────────────────────────────
step "1/6" "tofu apply — stacks/infra"
cd "$INFRA_DIR"
tofu init -input=false -upgrade=false >/dev/null
tofu apply -input=false -auto-approve

# Load IPs from tofu output now that infra state is populated.
# shellcheck disable=SC1091
. "$REPO_ROOT/tools/lib/lxc-ips.sh"
sub "IPs loaded: $ALL_LXC_IPS"

# ───────────────────────────────────────────────────────────────────────────────
step "2/6" "wait for service LXCs to be SSH-reachable"
# Clean stale known_hosts entries — LXCs may have been recreated with new host keys.
for ip in $ALL_LXC_IPS; do
  ssh-keygen -R "$ip" >/dev/null 2>&1 || true
done
for ip in $ALL_LXC_IPS; do
  sub "$ip"
  wait_ssh "$ip"
done

# ───────────────────────────────────────────────────────────────────────────────
step "3/6" "bootstrap service LXCs"

sub "adguard ($IP_ADGUARD): install AGH binary"
ssh root@"$IP_ADGUARD" 'sh -s' < "$REPO_ROOT/configs/adguard/scripts/bootstrap.sh"
if [ -x "$REPO_ROOT/configs/adguard/scripts/sync.sh" ]; then
  "$REPO_ROOT/configs/adguard/scripts/sync.sh"
fi

sub "gateway ($IP_GATEWAY): install Caddy + Authelia + generate OIDC keys"
ssh root@"$IP_GATEWAY" 'sh -s' < "$REPO_ROOT/configs/gateway/scripts/bootstrap.sh"
if [ -x "$REPO_ROOT/configs/authelia/scripts/sync.sh" ]; then
  "$REPO_ROOT/configs/authelia/scripts/sync.sh"
fi
if [ -x "$REPO_ROOT/configs/gateway/scripts/sync.sh" ]; then
  "$REPO_ROOT/configs/gateway/scripts/sync.sh"
fi

sub "coolify-runner-01 ($IP_RUNNER): install Docker"
ssh root@"$IP_RUNNER" 'sh -s' < "$REPO_ROOT/configs/coolify-runner/scripts/bootstrap.sh"

# ───────────────────────────────────────────────────────────────────────────────
step "4/6" "install cloudflared connectors (Coolify + runner replica for HA)"
TUNNEL_TOKEN=$(cd "$INFRA_DIR" && tofu output -raw tunnel_token)
# Same tunnel, two connectors → 8 outbound connections across 2 LXCs. If
# either host reboots, the other keeps serving. Cloudflare routes to the
# geographically closest replica automatically.
for host in "$IP_COOLIFY" "$IP_RUNNER"; do
  sub "cloudflared on $host"
  ssh root@"$host" "TUNNEL_TOKEN=$TUNNEL_TOKEN sh -s" \
    < "$REPO_ROOT/configs/cloudflared/scripts/install.sh"
done

# ───────────────────────────────────────────────────────────────────────────────
step "5/6" "bootstrap Coolify (install + create root user + mint API token)"
COOLIFY_HOST="$IP_COOLIFY" "$REPO_ROOT/configs/coolify/scripts/bootstrap.sh"

# ───────────────────────────────────────────────────────────────────────────────
step "6/8" "tofu apply — stacks/platform (register runner in Coolify)"
cd "$PLATFORM_DIR"
tofu init -input=false -upgrade=false >/dev/null
tofu apply -input=false -auto-approve

# ───────────────────────────────────────────────────────────────────────────────
step "7/8" "trigger Coolify's Docker engine validation on runner"
# Coolify's API server-create endpoint runs validateConnection (SSH) but NOT
# validateDockerEngine. Without this, is_usable stays false until you click
# "Validate" in the UI. Kick it manually via tinker so the runner is ready
# for deploys at end-of-rebuild.
ssh root@"$IP_COOLIFY" "docker exec coolify php artisan tinker --execute='
\$s = App\\Models\\Server::where(\"name\", \"coolify-runner-01\")->first();
if (\$s) { \$s->validateDockerEngine(); }
' 2>&1" | tail -3

# ───────────────────────────────────────────────────────────────────────────────
step "8/8" "sync ops LXC cron jobs (drift detection + token rotation)"
# Single declarative source: configs/ops-cron/iac.cron. Copy-if-different so
# we don't trigger cron's "file changed" reload when nothing actually changed.
install -d -m 0755 /etc/cron.d
if ! cmp -s "$REPO_ROOT/configs/ops-cron/iac.cron" /etc/cron.d/iac 2>/dev/null; then
  install -m 0644 "$REPO_ROOT/configs/ops-cron/iac.cron" /etc/cron.d/iac
  sub "installed /etc/cron.d/iac"
else
  sub "/etc/cron.d/iac up-to-date"
fi
# Ensure log targets exist with restrictive perms (cron creates them otherwise
# as world-readable).
for log in /var/log/iac-drift.log /var/log/coolify-token-rotation.log; do
  [ -e "$log" ] || { touch "$log"; chmod 640 "$log"; }
done

# ───────────────────────────────────────────────────────────────────────────────
printf '\n\033[1;32m✓ rebuild complete\033[0m\n'
echo "  Coolify UI:  https://coolify.iedora.com"
echo "  Authelia UI: https://auth.iedora.com"
echo "  AdGuard UI:  https://adguard.iedora.com (via gateway with SSO)"
ADMIN_EMAIL=$(bws secret list --output json | jq -r '.[] | select(.key=="IEDORA_ADMIN_EMAIL") | .value')
echo "  Admin email: $ADMIN_EMAIL"
echo "  Admin pass:  bws secret list --output json | jq -r '.[] | select(.key==\"IEDORA_ADMIN_PASSWORD\") | .value'"
