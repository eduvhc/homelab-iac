#!/bin/sh
# Push this folder to the gateway LXC and restart Authelia.
set -e
cd "$(dirname "$0")/.."
HOST="root@192.168.50.40"
scp -q configuration.yml  "$HOST:/etc/authelia/configuration.yml"
scp -q users_database.yml "$HOST:/etc/authelia/users_database.yml"
ssh "$HOST" "chown authelia:authelia /etc/authelia/*.yml \
  && chmod 640 /etc/authelia/*.yml \
  && systemctl restart authelia \
  && sleep 2 && systemctl is-active authelia"
