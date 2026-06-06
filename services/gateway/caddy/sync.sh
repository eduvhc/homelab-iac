#!/bin/sh
# Render Caddyfile.tmpl with IPs from tofu, validate, push to gateway LXC,
# reload Caddy.
set -e
SCRIPT_DIR=$(cd "$(dirname "$0")" && pwd)
REPO_ROOT=${SCRIPT_DIR%/services/*}
export PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin
# shellcheck disable=SC1091
. "$REPO_ROOT/iac/.envrc"
# shellcheck disable=SC1091
. "$REPO_ROOT/tools/lib/lxc-ips.sh"

cd "$SCRIPT_DIR"
HOST="root@$IP_GATEWAY"

RENDER_DIR=$(mktemp -d)
trap 'rm -rf "$RENDER_DIR"' EXIT

# Restrict envsubst to known vars so we never silently overwrite Caddy's own
# ${...} placeholders (Caddy uses {env.X} and {$X}, but be defensive).
envsubst '$IP_COOLIFY $IP_ADGUARD' < Caddyfile.tmpl > "$RENDER_DIR/Caddyfile"

command -v caddy >/dev/null && caddy validate --config "$RENDER_DIR/Caddyfile" 2>&1 | tail -3 || true
scp -q "$RENDER_DIR/Caddyfile" "$HOST:/etc/caddy/Caddyfile"
ssh "$HOST" "(systemctl reload caddy 2>/dev/null || systemctl restart caddy) \
  && sleep 1 && systemctl is-active caddy"
