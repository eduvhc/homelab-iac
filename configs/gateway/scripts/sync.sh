#!/bin/sh
# Push the Caddyfile to the gateway LXC and reload Caddy.
set -e
SCRIPT_DIR=$(cd "$(dirname "$0")" && pwd)
REPO_ROOT=${SCRIPT_DIR%/configs/*}
export PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin
# shellcheck disable=SC1091
. "$REPO_ROOT/iac/.envrc"
# shellcheck disable=SC1091
. "$REPO_ROOT/tools/lib/lxc-ips.sh"

cd "$SCRIPT_DIR/.."
HOST="root@$IP_GATEWAY"
command -v caddy >/dev/null && caddy validate --config Caddyfile 2>&1 | tail -3 || true
scp -q Caddyfile "$HOST:/etc/caddy/Caddyfile"
ssh "$HOST" "(systemctl reload caddy 2>/dev/null || systemctl restart caddy) \
  && sleep 1 && systemctl is-active caddy"
