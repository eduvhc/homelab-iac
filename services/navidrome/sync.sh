#!/bin/sh
# Push Navidrome config + systemd unit to the navidrome LXC. Idempotent:
# test-then-mutate per file. Only restart navidrome if something changed.
# Only daemon-reload if the unit file changed.
#
# Same pattern as services/gateway/authelia/sync.sh.
set -e
SCRIPT_DIR=$(cd "$(dirname "$0")" && pwd)
REPO_ROOT=${SCRIPT_DIR%/services/*}
export PATH="/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin:${PATH:-}"
# shellcheck disable=SC1091
. "$REPO_ROOT/tools/lib/core/common.sh"
source_envrc
# shellcheck disable=SC1091
. "$REPO_ROOT/tools/lib/infra/tofu.sh"
# shellcheck disable=SC1091
. "$REPO_ROOT/tools/lib/core/push.sh"

cd "$SCRIPT_DIR"
HOST="root@$IP_NAVIDROME"

# ── 1. Render template ──────────────────────────────────────────────────────
RENDER_DIR=$(mktemp -d)
trap 'rm -rf "$RENDER_DIR"' EXIT

envsubst '$IP_GATEWAY' < navidrome.toml.tmpl > "$RENDER_DIR/navidrome.toml"

# ── 2. Push if changed ──────────────────────────────────────────────────────
CONFIG_CHANGED=0
UNIT_CHANGED=0

if needs_push "$RENDER_DIR/navidrome.toml" /etc/navidrome/navidrome.toml; then
  scp -q "$RENDER_DIR/navidrome.toml" "$HOST:/etc/navidrome/navidrome.toml"
  CONFIG_CHANGED=1
fi
if needs_push navidrome.service /etc/systemd/system/navidrome.service; then
  scp -q navidrome.service "$HOST:/etc/systemd/system/navidrome.service"
  UNIT_CHANGED=1
fi

if [ $CONFIG_CHANGED -eq 1 ] || [ $UNIT_CHANGED -eq 1 ]; then
  CMDS="chown navidrome:navidrome /etc/navidrome/navidrome.toml && chmod 640 /etc/navidrome/navidrome.toml"
  [ $UNIT_CHANGED -eq 1 ] && CMDS="$CMDS && systemctl daemon-reload"
  CMDS="$CMDS && systemctl restart navidrome && sleep 2 && systemctl is-active navidrome"
  ssh "$HOST" "$CMDS"
  echo "navidrome: changes pushed → restarted"
else
  echo "navidrome: no changes"
fi
