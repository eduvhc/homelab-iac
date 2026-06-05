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
# Re-runs assume each LXC accepts the ops pubkey for SSH. Phase 3 attempts
# ssh-copy-id once per LXC; manual key trust beforehand is fine too.

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

# ───────────────────────────────────────────────────────────────────────────────
step "2/6" "wait for service LXCs to be SSH-reachable"
for ip in 192.168.50.30 192.168.50.40 192.168.50.200 192.168.50.210; do
  sub "$ip"
  wait_ssh "$ip"
done

# ───────────────────────────────────────────────────────────────────────────────
step "3/6" "bootstrap service LXCs"

sub "adguard (192.168.50.30): install AGH binary"
ssh root@192.168.50.30 'sh -s' < "$REPO_ROOT/configs/adguard/scripts/bootstrap.sh"
if [ -x "$REPO_ROOT/configs/adguard/scripts/sync.sh" ]; then
  "$REPO_ROOT/configs/adguard/scripts/sync.sh"
fi

sub "gateway (192.168.50.40): install Caddy + Authelia + generate OIDC keys"
ssh root@192.168.50.40 'sh -s' < "$REPO_ROOT/configs/gateway/scripts/bootstrap.sh"
if [ -x "$REPO_ROOT/configs/authelia/scripts/sync.sh" ]; then
  "$REPO_ROOT/configs/authelia/scripts/sync.sh"
fi
if [ -x "$REPO_ROOT/configs/gateway/scripts/sync.sh" ]; then
  "$REPO_ROOT/configs/gateway/scripts/sync.sh"
fi

sub "coolify-runner-01 (192.168.50.210): install Docker"
ssh root@192.168.50.210 'sh -s' < "$REPO_ROOT/configs/coolify-runner/scripts/bootstrap.sh"

# ───────────────────────────────────────────────────────────────────────────────
step "4/6" "install cloudflared on Coolify LXC"
TUNNEL_TOKEN=$(cd "$INFRA_DIR" && tofu output -raw tunnel_token)
if ssh root@192.168.50.200 'systemctl is-active --quiet cloudflared'; then
  sub "cloudflared already running — skipping install"
else
  ssh root@192.168.50.200 "
    set -e
    export DEBIAN_FRONTEND=noninteractive
    mkdir -p --mode=0755 /usr/share/keyrings
    if [ ! -s /usr/share/keyrings/cloudflare-main.gpg ]; then
      curl -fsSL https://pkg.cloudflare.com/cloudflare-main.gpg \
        -o /usr/share/keyrings/cloudflare-main.gpg
    fi
    if [ ! -s /etc/apt/sources.list.d/cloudflared.list ]; then
      echo 'deb [signed-by=/usr/share/keyrings/cloudflare-main.gpg] https://pkg.cloudflare.com/cloudflared bookworm main' \
        > /etc/apt/sources.list.d/cloudflared.list
    fi
    apt-get update -qq
    apt-get install -y -qq cloudflared
    cloudflared service install $TUNNEL_TOKEN
  "
fi

# ───────────────────────────────────────────────────────────────────────────────
step "5/6" "bootstrap Coolify (install + create root user + mint API token)"
"$REPO_ROOT/configs/coolify/scripts/bootstrap.sh"

# ───────────────────────────────────────────────────────────────────────────────
step "6/6" "tofu apply — stacks/platform (register runner in Coolify)"
cd "$PLATFORM_DIR"
tofu init -input=false -upgrade=false >/dev/null
tofu apply -input=false -auto-approve

# ───────────────────────────────────────────────────────────────────────────────
printf '\n\033[1;32m✓ rebuild complete\033[0m\n'
echo "  Coolify UI:  https://coolify.iedora.com"
echo "  Authelia UI: https://auth.iedora.com"
echo "  AdGuard UI:  https://adguard.iedora.com (via gateway with SSO)"
echo "  Admin email: $(bws secret list --output json | jq -r '.[] | select(.key==\"IEDORA_ADMIN_EMAIL\") | .value')"
echo "  Admin pass:  bws secret list --output json | jq -r '.[] | select(.key==\"IEDORA_ADMIN_PASSWORD\") | .value'"
