#!/bin/sh
# Push this folder to the AdGuard LXC and restart services.
set -e
SCRIPT_DIR=$(cd "$(dirname "$0")" && pwd)
REPO_ROOT=${SCRIPT_DIR%/configs/*}
export PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin
# shellcheck disable=SC1091
. "$REPO_ROOT/iac/.envrc"
# shellcheck disable=SC1091
. "$REPO_ROOT/tools/lib/lxc-ips.sh"

cd "$SCRIPT_DIR/.."
HOST="root@$IP_ADGUARD"
python3 -c "import yaml; yaml.safe_load(open(\"AdGuardHome.yaml\"))"
scp -q AdGuardHome.yaml "$HOST:/opt/AdGuardHome/AdGuardHome.yaml"
scp -q nftables.conf    "$HOST:/etc/nftables.conf"
ssh "$HOST" "chmod 600 /opt/AdGuardHome/AdGuardHome.yaml \
  && nft -c -f /etc/nftables.conf \
  && systemctl restart AdGuardHome nftables \
  && sleep 2 && systemctl is-active AdGuardHome nftables"
