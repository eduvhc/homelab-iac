#!/bin/sh
# Render AdGuardHome.yaml.tmpl + nftables.conf.tmpl with IPs from tofu,
# validate, push to AdGuard LXC, restart services.
set -e
SCRIPT_DIR=$(cd "$(dirname "$0")" && pwd)
REPO_ROOT=${SCRIPT_DIR%/services/*}
export PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin
# shellcheck disable=SC1091
. "$REPO_ROOT/iac/.envrc"
# shellcheck disable=SC1091
. "$REPO_ROOT/tools/lib/lxc-ips.sh"

cd "$SCRIPT_DIR"
HOST="root@$IP_ADGUARD"

RENDER_DIR=$(mktemp -d)
trap 'rm -rf "$RENDER_DIR"' EXIT

envsubst '$IP_GATEWAY $IP_COOLIFY' < AdGuardHome.yaml.tmpl > "$RENDER_DIR/AdGuardHome.yaml"
envsubst '$LAN_CIDR $IP_GATEWAY'   < nftables.conf.tmpl    > "$RENDER_DIR/nftables.conf"

python3 -c "import yaml; yaml.safe_load(open('$RENDER_DIR/AdGuardHome.yaml'))"
scp -q "$RENDER_DIR/AdGuardHome.yaml" "$HOST:/opt/AdGuardHome/AdGuardHome.yaml"
scp -q "$RENDER_DIR/nftables.conf"    "$HOST:/etc/nftables.conf"
ssh "$HOST" "chmod 600 /opt/AdGuardHome/AdGuardHome.yaml \
  && nft -c -f /etc/nftables.conf \
  && systemctl restart AdGuardHome nftables \
  && sleep 2 && systemctl is-active AdGuardHome nftables"
