#!/bin/sh
# Destroy: tear down the iedora homelab. Destroys everything tofu manages
# (LXCs 102/103/200/210 + CF tunnel + DNS records + Coolify-side objects).
# Counterpart to tools/apply.sh.
#
# NOT destroyed:
#   - The ops LXC (101) — where this runs
#   - BWS secrets — survive (re-usable by next apply)
#   - Cloudflare zone — only the records/tunnel we created
#   - The /etc/cron.d/iac entry on the ops LXC (still references apply.sh; if
#     re-applying soon, leave it; otherwise: rm /etc/cron.d/iac manually)
#
# Order is REVERSE of apply.sh: platform → infra. Platform depends on infra
# (terraform_remote_state), so it must be destroyed first while infra state
# is still valid.
#
# Re-running is safe: tofu destroy on an empty state is a no-op.

set -eu

export PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin

SCRIPT_DIR=$(cd "$(dirname "$0")" && pwd)
REPO_ROOT=${SCRIPT_DIR%/tools}
# shellcheck disable=SC1091
. "$REPO_ROOT/iac/.envrc"

INFRA_DIR="$REPO_ROOT/iac/stacks/infra"
PLATFORM_DIR="$REPO_ROOT/iac/stacks/platform"

step() { printf '\n\033[1;31m[%s]\033[0m %s\n' "$1" "$2"; }

# ── Confirmation ──────────────────────────────────────────────────────────────
# Skipped if AUTO_APPROVE=1 in env (for scripted nuke + rebuild flows).
if [ "${AUTO_APPROVE:-0}" != "1" ]; then
  printf '\033[1;31m'
  printf 'About to DESTROY:\n'
  printf '  • LXCs 102 (adguard), 103 (gateway), 200 (coolify), 210 (runner)\n'
  printf '    → every app deployed by Coolify is wiped\n'
  printf '    → Authelia user DB + AdGuard query logs are lost\n'
  printf '  • Cloudflare tunnel "coolify-iedora" + 4 DNS records\n'
  printf '  • Coolify-side: registered server, private_key\n'
  printf '\033[0m'
  printf '\nType "destroy" to confirm: '
  read -r CONFIRM
  [ "$CONFIRM" = "destroy" ] || { echo "Aborted."; exit 1; }
fi

# ── Platform first (depends on infra outputs) ─────────────────────────────────
step "1/2" "tofu destroy — stacks/platform"
cd "$PLATFORM_DIR"
tofu init -input=false -upgrade=false >/dev/null
tofu destroy -auto-approve -input=false

# ── Infra (LXCs + CF tunnel + DNS) ────────────────────────────────────────────
step "2/2" "tofu destroy — stacks/infra"
cd "$INFRA_DIR"
tofu init -input=false -upgrade=false >/dev/null
tofu destroy -auto-approve -input=false

printf '\n\033[1;31m✓ destroy complete\033[0m\n'
printf '  Run tools/apply.sh to recreate everything from scratch.\n'
