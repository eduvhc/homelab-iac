#!/bin/bash
# Thin wrapper: ssh + docker exec + run target/bootstrap-user.php in the
# coolify container. The PHP itself (the meat — create or update root
# user, idempotent password sync) lives in target/bootstrap-user.php for
# editability + syntax highlighting.
#
# Inputs from iac/secrets.sops.yaml via source_envrc:
#   HOMELAB_ADMIN_NAME, HOMELAB_ADMIN_EMAIL, HOMELAB_ADMIN_PASSWORD

set -euo pipefail

SCRIPT_DIR=$(cd "$(dirname "$0")" && pwd)
# shellcheck disable=SC1091
. "$SCRIPT_DIR/../../../tools/lib/core/common.sh"

source_envrc
require_cmd ssh

HOST=${COOLIFY_HOST:-192.168.50.200}
PHP_FILE="$SCRIPT_DIR/../target/bootstrap-user.php"

ESC_NAME=$(printf '%s' "${HOMELAB_ADMIN_NAME:?}" | sed "s/'/'\\\\''/g")
ESC_EMAIL=$(printf '%s' "${HOMELAB_ADMIN_EMAIL:?}" | sed "s/'/'\\\\''/g")
ESC_PASS=$(printf '%s' "${HOMELAB_ADMIN_PASSWORD:?}" | sed "s/'/'\\\\''/g")

log_info "ensure root user + password matches sops"
# Strip the leading `<?php` (kept in the file for editor highlighting) —
# tinker --execute expects bare PHP code, not a full PHP file.
PHP_CODE=$(sed -e '1{/^<?php/d}' "$PHP_FILE")
result=$(ssh root@"$HOST" \
  "docker exec -e COOLIFY_BOOTSTRAP_NAME='$ESC_NAME' \
     -e COOLIFY_BOOTSTRAP_EMAIL='$ESC_EMAIL' \
     -e COOLIFY_BOOTSTRAP_PASS='$ESC_PASS' \
     coolify php artisan tinker --execute=$(printf '%q' "$PHP_CODE")" \
  | grep -oE 'USER_(UNCHANGED|UPDATED|CREATED)=[0-9]+(:[a-z,]+)?' | head -1)

case "$result" in
  USER_UNCHANGED=*) log_info "user unchanged (id=${result#USER_UNCHANGED=})" ;;
  USER_UPDATED=*)   log_info "user updated (${result#USER_UPDATED=})" ;;
  USER_CREATED=*)   log_info "user created (id=${result#USER_CREATED=})" ;;
  *)                die "unexpected output: $result" ;;
esac
