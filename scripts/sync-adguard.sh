#!/bin/sh
# Push the local AdGuardHome.yaml to the AdGuard LXC and restart the service.
# Run from the repo root: scripts/sync-adguard.sh
set -e
HOST="root@192.168.50.30"
LOCAL="configs/adguard/AdGuardHome.yaml"
REMOTE="/opt/AdGuardHome/AdGuardHome.yaml"

[ -f "$LOCAL" ] || { echo "missing $LOCAL"; exit 1; }
echo "==> validating yaml syntax"
python3 -c "import yaml; yaml.safe_load(open(\"$LOCAL\"))"
echo "==> pushing to $HOST"
scp -q "$LOCAL" "$HOST:$REMOTE"
ssh "$HOST" "chmod 600 $REMOTE && systemctl restart AdGuardHome"
echo "==> verifying"
ssh "$HOST" "systemctl is-active AdGuardHome"
