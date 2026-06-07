# shellcheck shell=sh
# Source this from any tool/script that needs LXC IPs or network constants.
#
# Single source of truth: iac/stacks/infra/locals.tf → outputs lxc_ips + network.
# This script reads them via tofu output and exports canonical env vars so
# consumers never hardcode an IP. Used by tools/apply.sh and configs/*/sync.sh
# (including envsubst rendering of *.tmpl config files).
#
# Usage:
#   . "$REPO_ROOT/tools/lib/lxc-ips.sh"
#   ssh root@"$IP_COOLIFY" ...
#   envsubst < Caddyfile.tmpl > Caddyfile
#   for ip in $ALL_LXC_IPS; do ...; done
#
# Pre-reqs:
#   - $REPO_ROOT set to the homelab-iac repo root
#   - source_envrc has run (TF_VAR_tf_state_passphrase set)
#   - stacks/infra is initialized and applied at least once

set -e

[ -n "${REPO_ROOT:-}" ] || { echo "lxc-ips.sh: REPO_ROOT not set" >&2; exit 1; }
command -v tofu >/dev/null || { echo "lxc-ips.sh: tofu not in PATH" >&2; exit 1; }
command -v jq >/dev/null   || { echo "lxc-ips.sh: jq not in PATH" >&2; exit 1; }

# Single tofu invocation reading all outputs at once — saves ~1s.
_infra_outputs=$(cd "$REPO_ROOT/iac/stacks/infra" && tofu output -json 2>/dev/null) || {
  echo "lxc-ips.sh: tofu output -json failed (has stacks/infra been applied?)" >&2
  exit 1
}

_get() { printf '%s' "$_infra_outputs" | jq -r ".$1.value$2"; }

# LXC IPs.
IP_ADGUARD=$(  _get lxc_ips .adguard)
IP_GATEWAY=$(  _get lxc_ips .gateway)
IP_COOLIFY=$(  _get lxc_ips .coolify)
IP_RUNNER=$(   _get lxc_ips '["coolify-runner-01"]')
IP_NAVIDROME=$(_get lxc_ips .navidrome)
ALL_LXC_IPS="$IP_ADGUARD $IP_GATEWAY $IP_COOLIFY $IP_RUNNER $IP_NAVIDROME"

# Network constants.
LAN_CIDR=$(   _get network .lan_cidr)
LAN_GATEWAY=$(_get network .lan_gateway)

# Service URLs.
COOLIFY_API_URL=$(_get coolify_api_url '')

# Fail loud if any expected value is empty or "null" — envsubst would otherwise
# silently render "" into the config files (e.g. AdGuard rewrites pointing to
# nothing, Caddy reverse_proxy to http://:80).
_val=
for _var in IP_ADGUARD IP_GATEWAY IP_COOLIFY IP_RUNNER IP_NAVIDROME LAN_CIDR LAN_GATEWAY COOLIFY_API_URL; do
  eval "_val=\$$_var"
  case $_val in
    ''|null)
      echo "lxc-ips.sh: $_var is empty (tofu output returned '$_val') — has stacks/infra been applied?" >&2
      exit 1
      ;;
  esac
done
unset _var _val

export IP_ADGUARD IP_GATEWAY IP_COOLIFY IP_RUNNER IP_NAVIDROME ALL_LXC_IPS
export LAN_CIDR LAN_GATEWAY COOLIFY_API_URL
unset _infra_outputs
