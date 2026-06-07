# shellcheck shell=sh
# Resolve a service-name → IP lookup directly from network/ips.yaml,
# without going through tofu output. Use this from cron-driven scripts
# (backup-*.sh, etc.) where the full lxc-ips.sh round-trip via tofu
# state is overkill.
#
# tools/lib/lxc-ips.sh remains the canonical source for the apply
# pipeline (single tofu call, exports everything). This helper exists
# for hot paths that just need one IP and don't want a tofu dependency.
#
# Usage:
#   . "$REPO_ROOT/tools/lib/ip-from-yaml.sh"
#   HOST=root@$(ip_of gateway)
#
# Pre-req: $REPO_ROOT set.

# ip_of SERVICE — print the IP of the named service from
# network/ips.yaml. Returns 1 + empty output if not found. State-machine
# awk: only matches inside the `services:` block, so we never collide
# with e.g. `lan.gateway` which has the same key name.
ip_of() {
  [ -n "${REPO_ROOT:-}" ] || { echo "ip_of: REPO_ROOT not set" >&2; return 1; }
  [ -n "${1:-}" ]         || { echo "ip_of: missing service name" >&2; return 1; }
  _name=$1
  _ip=$(awk -v want="$_name" '
    /^services:/ { in_svc = 1; next }
    /^[^[:space:]]/ { in_svc = 0 }                # any non-indented line ends the block
    in_svc && $1 == want":" { print $2; exit }
  ' "$REPO_ROOT/network/ips.yaml")
  [ -n "$_ip" ] || { echo "ip_of: service '$_name' not in network/ips.yaml" >&2; return 1; }
  printf '%s\n' "$_ip"
}
