#!/bin/sh
# Push AdGuardHome.yaml + nftables.conf to LXC 102 and reload.
set -e
HOST="root@192.168.50.30"
YAML_LOCAL="configs/adguard/AdGuardHome.yaml"
NFT_LOCAL="configs/adguard/nftables.conf"

echo "==> validating AdGuard yaml syntax"
python3 -c "import yaml; yaml.safe_load(open(\"$YAML_LOCAL\"))"

echo "==> pushing AdGuard config"
scp -q "$YAML_LOCAL" "$HOST:/opt/AdGuardHome/AdGuardHome.yaml"
ssh "$HOST" "chmod 600 /opt/AdGuardHome/AdGuardHome.yaml && systemctl restart AdGuardHome"

echo "==> pushing nftables ruleset"
scp -q "$NFT_LOCAL" "$HOST:/etc/nftables.conf"
ssh "$HOST" "nft -c -f /etc/nftables.conf && systemctl restart nftables"

echo "==> verifying"
ssh "$HOST" "systemctl is-active AdGuardHome nftables"
