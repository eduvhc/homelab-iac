#!/bin/sh
# Render templates with IPs from tofu → validate → push to AdGuard LXC →
# restart services. Idempotent: test-then-mutate via sha256 compare; nothing
# changes on the host if config is already up-to-date.
set -e
SCRIPT_DIR=$(cd "$(dirname "$0")" && pwd)
REPO_ROOT=${SCRIPT_DIR%/services/*}
export PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin
# shellcheck disable=SC1091
. "$REPO_ROOT/tools/lib/common.sh"
source_envrc
# shellcheck disable=SC1091
. "$REPO_ROOT/tools/lib/lxc-ips.sh"
# shellcheck disable=SC1091
. "$REPO_ROOT/tools/lib/sync.sh"

cd "$SCRIPT_DIR"
HOST="root@$IP_ADGUARD"

RENDER_DIR=$(mktemp -d)
trap 'rm -rf "$RENDER_DIR"' EXIT

envsubst '$IP_GATEWAY $IP_COOLIFY $HOMELAB_DOMAIN' < AdGuardHome.yaml.tmpl > "$RENDER_DIR/AdGuardHome.yaml"
envsubst '$LAN_CIDR $IP_GATEWAY'   < nftables.conf.tmpl    > "$RENDER_DIR/nftables.conf"

python3 -c "import yaml; yaml.safe_load(open('$RENDER_DIR/AdGuardHome.yaml'))"

CHANGED=0
if needs_push "$RENDER_DIR/AdGuardHome.yaml" /opt/AdGuardHome/AdGuardHome.yaml; then
  scp -q "$RENDER_DIR/AdGuardHome.yaml" "$HOST:/opt/AdGuardHome/AdGuardHome.yaml"
  CHANGED=1
fi
if needs_push "$RENDER_DIR/nftables.conf" /etc/nftables.conf; then
  scp -q "$RENDER_DIR/nftables.conf" "$HOST:/etc/nftables.conf"
  CHANGED=1
fi

if [ $CHANGED -eq 1 ]; then
  ssh "$HOST" "chmod 600 /opt/AdGuardHome/AdGuardHome.yaml \
    && nft -c -f /etc/nftables.conf \
    && systemctl restart AdGuardHome nftables \
    && sleep 2 && systemctl is-active AdGuardHome nftables"
  echo "adguard: config changed → services restarted"
else
  echo "adguard: no changes"
fi
