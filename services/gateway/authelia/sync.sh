#!/bin/sh
# Hybrid sync for Authelia: bespoke argon2id hash management, then dispatch
# to the declarative sync engine for the actual render+push of all files.
#
# Password sync (the bit that stays shell):
#   HOMELAB_ADMIN_PASSWORD lives in sops as the operator-provided source
#   of truth. Authelia needs an argon2id hash, which is non-deterministic
#   (random salt per generation). To avoid spurious drift on every run,
#   we store the hash AND a sha256 marker of the source password in sops:
#     HOMELAB_ADMIN_PWHASH       — current argon2id digest
#     HOMELAB_ADMIN_PWHASH_SRC   — sha256(HOMELAB_ADMIN_PASSWORD) at hash time
#   If the marker matches the current password's sha256, reuse the hash.
#   Otherwise regenerate via `authelia crypto hash generate argon2` on the
#   gateway (where the binary lives) and update both sops keys.
#
# Render+push (delegated): services/gateway/authelia/sync.yaml describes the
# three files (configuration.yml, users_database.yml, authelia.service) and
# their atomic_push + chown + restart triggers. The Go engine reads it after
# this script exports HOMELAB_ADMIN_PWHASH into the environment.

set -e
SCRIPT_DIR=$(cd "$(dirname "$0")" && pwd)
REPO_ROOT=${SCRIPT_DIR%/services/*}
export REPO_ROOT
export PATH="/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin:${PATH:-}"
# shellcheck disable=SC1091
. "$REPO_ROOT/tools/lib/core/common.sh"
source_envrc
# shellcheck disable=SC1091
. "$REPO_ROOT/tools/lib/infra/tofu.sh"
# shellcheck disable=SC1091
. "$REPO_ROOT/tools/lib/secrets/sops.sh"

HOST="root@$IP_GATEWAY"

# ── Ensure HOMELAB_ADMIN_PWHASH matches HOMELAB_ADMIN_PASSWORD ──────────────
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

# ── Dispatch to the declarative sync engine ─────────────────────────────────
cd "$REPO_ROOT/tools/lib/sync" && exec go run . "$REPO_ROOT/services/gateway/authelia/sync.yaml"
