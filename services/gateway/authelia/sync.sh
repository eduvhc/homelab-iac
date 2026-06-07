#!/bin/sh
# Push Authelia configs + systemd unit to the gateway LXC. Idempotent:
# test-then-mutate per file. Only restart authelia if something changed.
# Only daemon-reload if the unit file changed.
#
# Password sync:
#   HOMELAB_ADMIN_PASSWORD lives in sops as the operator-provided source
#   of truth. Authelia needs an argon2id hash, which is non-deterministic
#   (random salt per generation). To avoid spurious drift on every run,
#   we store the hash AND a sha256 marker of the source password in sops:
#     HOMELAB_ADMIN_PWHASH       — current argon2id digest
#     HOMELAB_ADMIN_PWHASH_SRC   — sha256(HOMELAB_ADMIN_PASSWORD) at hash time
#   If the marker matches the current password's sha256, reuse the hash.
#   Otherwise regenerate via `authelia crypto hash generate argon2` on the
#   gateway (where the binary lives) and update both sops keys.

set -e
SCRIPT_DIR=$(cd "$(dirname "$0")" && pwd)
REPO_ROOT=${SCRIPT_DIR%/services/*}
export PATH="/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin:${PATH:-}"
# shellcheck disable=SC1091
. "$REPO_ROOT/tools/lib/core/common.sh"
source_envrc
# shellcheck disable=SC1091
. "$REPO_ROOT/tools/lib/secrets/sops.sh"
# shellcheck disable=SC1091
. "$REPO_ROOT/tools/lib/infra/tofu.sh"
# shellcheck disable=SC1091
. "$REPO_ROOT/tools/lib/core/push.sh"

cd "$SCRIPT_DIR"
HOST="root@$IP_GATEWAY"

# ── 1. Ensure HOMELAB_ADMIN_PWHASH matches HOMELAB_ADMIN_PASSWORD ────────────
pw_sha=$(printf %s "$HOMELAB_ADMIN_PASSWORD" | sha256sum | cut -d' ' -f1)
stored_sha=$(sops_get HOMELAB_ADMIN_PWHASH_SRC)
stored_hash=$(sops_get HOMELAB_ADMIN_PWHASH)

if [ -z "$stored_hash" ] || [ "$pw_sha" != "$stored_sha" ]; then
  log_info "regenerating Authelia password hash"
  # Quote-escape the password for single-quoted shell context on the remote.
  esc_pw=$(printf '%s' "$HOMELAB_ADMIN_PASSWORD" | sed "s/'/'\\\\''/g")
  new_hash=$(ssh "$HOST" "authelia crypto hash generate argon2 --password '$esc_pw'" \
             | sed -n 's/^Digest: //p')
  [ -n "$new_hash" ] || die "authelia hash generation returned empty"
  sops_set HOMELAB_ADMIN_PWHASH "$new_hash"
  sops_set HOMELAB_ADMIN_PWHASH_SRC "$pw_sha"
  export HOMELAB_ADMIN_PWHASH="$new_hash"
  log_info "hash refreshed → commit + push iac/secrets.sops.yaml"
else
  export HOMELAB_ADMIN_PWHASH="$stored_hash"
fi

# ── 2. Render templates ─────────────────────────────────────────────────────
RENDER_DIR=$(mktemp -d)
trap 'rm -rf "$RENDER_DIR"' EXIT

envsubst '$HOMELAB_DOMAIN' \
  < configuration.yml.tmpl > "$RENDER_DIR/configuration.yml"
envsubst '$HOMELAB_ADMIN_NAME $HOMELAB_ADMIN_EMAIL $HOMELAB_ADMIN_PWHASH' \
  < users_database.yml.tmpl > "$RENDER_DIR/users_database.yml"

# ── 3. Push if changed ──────────────────────────────────────────────────────
# Config files trigger `systemctl restart`. Unit file additionally triggers
# `daemon-reload`.
CONFIG_CHANGED=0
UNIT_CHANGED=0
for f in configuration.yml users_database.yml; do
  if needs_push "$RENDER_DIR/$f" "/etc/authelia/$f"; then
    atomic_push "$RENDER_DIR/$f" "/etc/authelia/$f"
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
