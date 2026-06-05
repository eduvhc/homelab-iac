#!/bin/sh
# Push the Caddyfile to the gateway LXC and reload Caddy.
set -e
cd "$(dirname "$0")"
HOST="root@192.168.50.40"
command -v caddy >/dev/null && caddy validate --config Caddyfile 2>&1 | tail -3 || true
scp -q Caddyfile "$HOST:/etc/caddy/Caddyfile"
ssh "$HOST" "(systemctl reload caddy 2>/dev/null || systemctl restart caddy) \
  && sleep 1 && systemctl is-active caddy"
