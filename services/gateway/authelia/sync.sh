#!/bin/sh
# Push Authelia configs + systemd unit to the gateway LXC. Idempotent:
# test-then-mutate per file; only restart authelia if something changed,
# only daemon-reload if the unit file changed.
set -e
SCRIPT_DIR=$(cd "$(dirname "$0")" && pwd)
REPO_ROOT=${SCRIPT_DIR%/services/*}
export PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin
# shellcheck disable=SC1091
. "$REPO_ROOT/iac/.envrc"
# shellcheck disable=SC1091
. "$REPO_ROOT/tools/lib/lxc-ips.sh"
# shellcheck disable=SC1091
. "$REPO_ROOT/tools/lib/sync.sh"

cd "$SCRIPT_DIR"
# Authelia runs on the gateway LXC, not its own LXC.
HOST="root@$IP_GATEWAY"

# Config files trigger `systemctl restart`; unit file additionally triggers
# `daemon-reload`.
CONFIG_CHANGED=0
UNIT_CHANGED=0
for f in configuration.yml users_database.yml; do
  if needs_push "$f" "/etc/authelia/$f"; then
    scp -q "$f" "$HOST:/etc/authelia/$f"
    CONFIG_CHANGED=1
  fi
done
if needs_push authelia.service /etc/systemd/system/authelia.service; then
  scp -q authelia.service "$HOST:/etc/systemd/system/authelia.service"
  UNIT_CHANGED=1
fi

if [ $CONFIG_CHANGED -eq 1 ] || [ $UNIT_CHANGED -eq 1 ]; then
  CMDS="chown authelia:authelia /etc/authelia/*.yml && chmod 640 /etc/authelia/*.yml"
  [ $UNIT_CHANGED -eq 1 ] && CMDS="$CMDS && systemctl daemon-reload"
  CMDS="$CMDS && systemctl restart authelia && sleep 2 && systemctl is-active authelia"
  ssh "$HOST" "$CMDS"
  echo "authelia: changes pushed → restarted"
else
  echo "authelia: no changes"
fi
