#!/bin/bash
# Destroy: tear down the homelab. Destroys everything tofu manages
# (LXCs 102/103/200/210 + CF tunnel + DNS records + Coolify-side objects).
# Counterpart to tools/apply.sh.
#
# Usage:
#   tools/destroy.sh [-h|--help]
#   AUTO_APPROVE=1 tools/destroy.sh    # skip the confirmation prompt
#
# NOT destroyed:
#   - The ops LXC (101) — where this runs
#   - iac/secrets.sops.yaml — survives (reusable by next apply)
#   - Cloudflare zone — only the records/tunnel we created
#   - R2 bucket homelab-iac-state — survives (holds tofu state itself)
#
# Order is REVERSE of apply.sh: platform → infra. Platform depends on infra
# (terraform_remote_state), so it must be destroyed first while infra state
# is still valid.
#
# Re-running is safe: tofu destroy on an empty state is a no-op.

set -eu
export PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin

SCRIPT_DIR=$(cd "$(dirname "$0")" && pwd)
# shellcheck disable=SC1091
. "$SCRIPT_DIR/lib/core/common.sh"

case "${1:-}" in
  -h|--help) sed -n '2,/^$/p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
esac

source_envrc
require_cmd tofu

if [ "${AUTO_APPROVE:-0}" != "1" ]; then
  cat >&2 <<'EOF'

About to DESTROY:
  • LXCs 102 (adguard), 103 (gateway), 200 (coolify), 210 (runner)
    → every app deployed by Coolify is wiped
    → Authelia user DB + AdGuard query logs are lost
  • Cloudflare tunnel "coolify-tunnel" + 4 DNS records
  • Coolify-side: registered server, private_key

EOF
  printf 'Type "destroy" to confirm: '
  read -r CONFIRM
  [ "$CONFIRM" = "destroy" ] || die "Aborted."
fi

log_step "1/2" "tofu destroy — stacks/platform"
cd "$REPO_ROOT/iac/stacks/platform"
tofu init -input=false -upgrade=false >/dev/null
tofu destroy -auto-approve -input=false

log_step "2/2" "tofu destroy — stacks/infra"
cd "$REPO_ROOT/iac/stacks/infra"
tofu init -input=false -upgrade=false >/dev/null
tofu destroy -auto-approve -input=false

printf '\n\033[1;31m✓ destroy complete\033[0m\n'
echo "  Run tools/apply.sh to recreate everything from scratch."
