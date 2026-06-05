# shellcheck shell=sh
# Source this from any tool/script that needs LXC IPs.
#
# Single source of truth: iac/stacks/infra/locals.tf → output `lxc_ips`.
# This script reads that output via `tofu output -json lxc_ips` and exports
# canonical IP_* env vars so consumers never hardcode an IP.
#
# Usage:
#   . "$REPO_ROOT/tools/lib/lxc-ips.sh"
#   ssh root@"$IP_COOLIFY" ...
#   for ip in $ALL_LXC_IPS; do ...; done
#
# Pre-reqs:
#   - $REPO_ROOT set to the iedora-iac repo root
#   - .envrc already sourced (TF_VAR_tf_state_passphrase set)
#   - stacks/infra is initialized and applied at least once

set -e

[ -n "${REPO_ROOT:-}" ] || { echo "lxc-ips.sh: REPO_ROOT not set" >&2; exit 1; }
command -v tofu >/dev/null || { echo "lxc-ips.sh: tofu not in PATH" >&2; exit 1; }
command -v jq >/dev/null   || { echo "lxc-ips.sh: jq not in PATH" >&2; exit 1; }

_lxc_ips_json=$(cd "$REPO_ROOT/iac/stacks/infra" && tofu output -json lxc_ips 2>/dev/null) || {
  echo "lxc-ips.sh: tofu output -json lxc_ips failed (has stacks/infra been applied?)" >&2
  exit 1
}
[ -n "$_lxc_ips_json" ] && [ "$_lxc_ips_json" != "null" ] || {
  echo "lxc-ips.sh: lxc_ips output is empty — has stacks/infra been applied?" >&2
  exit 1
}

# Exported, named uppercase by LXC role.
IP_ADGUARD=$(printf '%s' "$_lxc_ips_json" | jq -r .adguard)
IP_GATEWAY=$(printf '%s' "$_lxc_ips_json" | jq -r .gateway)
IP_COOLIFY=$(printf '%s' "$_lxc_ips_json" | jq -r .coolify)
IP_RUNNER=$(printf '%s'  "$_lxc_ips_json" | jq -r .coolify_runner_01)
ALL_LXC_IPS="$IP_ADGUARD $IP_GATEWAY $IP_COOLIFY $IP_RUNNER"

export IP_ADGUARD IP_GATEWAY IP_COOLIFY IP_RUNNER ALL_LXC_IPS
unset _lxc_ips_json
