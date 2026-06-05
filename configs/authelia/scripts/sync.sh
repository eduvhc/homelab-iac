#!/bin/sh
# Push Authelia configs + systemd unit to the gateway LXC and restart.
set -e
cd "$(dirname "$0")/.."
HOST="root@192.168.50.40"
scp -q configuration.yml   "$HOST:/etc/authelia/configuration.yml"
scp -q users_database.yml  "$HOST:/etc/authelia/users_database.yml"
scp -q authelia.service    "$HOST:/etc/systemd/system/authelia.service"
ssh "$HOST" "chown authelia:authelia /etc/authelia/*.yml \
  && chmod 640 /etc/authelia/*.yml \
  && systemctl daemon-reload \
  && systemctl restart authelia \
  && sleep 2 && systemctl is-active authelia"
