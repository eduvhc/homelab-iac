#!/bin/sh
# Push this folder to the AdGuard LXC and restart services.
set -e
cd "$(dirname "$0")"
HOST="root@192.168.50.30"
python3 -c "import yaml; yaml.safe_load(open(\"AdGuardHome.yaml\"))"
scp -q AdGuardHome.yaml "$HOST:/opt/AdGuardHome/AdGuardHome.yaml"
scp -q nftables.conf    "$HOST:/etc/nftables.conf"
ssh "$HOST" "chmod 600 /opt/AdGuardHome/AdGuardHome.yaml \
  && nft -c -f /etc/nftables.conf \
  && systemctl restart AdGuardHome nftables \
  && sleep 2 && systemctl is-active AdGuardHome nftables"
