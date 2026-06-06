#!/bin/sh
# Push Authelia configs + systemd unit to the gateway LXC and restart.
set -e
SCRIPT_DIR=$(cd "$(dirname "$0")" && pwd)
REPO_ROOT=${SCRIPT_DIR%/services/*}
export PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin
# shellcheck disable=SC1091
. "$REPO_ROOT/iac/.envrc"
# shellcheck disable=SC1091
. "$REPO_ROOT/tools/lib/lxc-ips.sh"

cd "$SCRIPT_DIR"
# Authelia runs on the gateway LXC, not its own LXC.
HOST="root@$IP_GATEWAY"
scp -q configuration.yml   "$HOST:/etc/authelia/configuration.yml"
scp -q users_database.yml  "$HOST:/etc/authelia/users_database.yml"
scp -q authelia.service    "$HOST:/etc/systemd/system/authelia.service"
ssh "$HOST" "chown authelia:authelia /etc/authelia/*.yml \
  && chmod 640 /etc/authelia/*.yml \
  && systemctl daemon-reload \
  && systemctl restart authelia \
  && sleep 2 && systemctl is-active authelia"
