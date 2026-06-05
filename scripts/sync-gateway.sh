#!/bin/sh
# Push Caddyfile + Authelia configs to the gateway LXC and reload services.
set -e
HOST="root@192.168.50.40"

echo "==> caddy validate"
caddy validate --config configs/gateway/Caddyfile 2>&1 | tail -3 || true

echo "==> pushing Caddyfile"
scp -q configs/gateway/Caddyfile "$HOST:/etc/caddy/Caddyfile"

echo "==> pushing Authelia configs"
scp -q configs/authelia/configuration.yml "$HOST:/etc/authelia/configuration.yml"
scp -q configs/authelia/users_database.yml "$HOST:/etc/authelia/users_database.yml"
ssh "$HOST" "chown authelia:authelia /etc/authelia/*.yml && chmod 640 /etc/authelia/*.yml"

echo "==> reloading services"
ssh "$HOST" "systemctl reload caddy 2>/dev/null || systemctl restart caddy; systemctl restart authelia"
ssh "$HOST" "sleep 2 && systemctl is-active caddy authelia"
