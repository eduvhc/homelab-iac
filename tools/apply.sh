#!/bin/bash
# Apply: converge the homelab to the desired state. Idempotent — safe
# to re-run. Use tools/destroy.sh for tear-down.
#
# Usage:
#   tools/apply.sh [-h|--help]
#
# Phases (each idempotent):
#   1. tofu apply iac/stacks/infra      (LXCs + CF tunnel + DNS)
#   2. wait for LXCs to be SSH-reachable
#   3. bootstrap service LXCs           (install binaries + per-service secrets)
#   4. install cloudflared connectors on Coolify + runner (HA)
#   5. bootstrap Coolify                (install + root user + ensure fresh token)
#   6. tofu apply iac/stacks/platform   (register runner in Coolify)
#   7. trigger Coolify Docker engine validation on runner
#   8. sync ops LXC cron jobs           (assembled from services/*/cron.yaml)
#
# Pre-reqs:
#   - All secrets + identifiers seeded (tools/seed-secrets.sh)
#   - sops + age installed; age private key at ~/.config/sops/age/keys.txt
#   - Ops LXC has /root/.ssh/id_ed25519 trusted by PVE root
#
# LXC IPs are NEVER hardcoded here. After Phase 1, tools/lib/infra/tofu.sh
# reads tofu output and exports IP_ADGUARD / IP_GATEWAY / IP_COOLIFY /
# IP_RUNNER / ALL_LXC_IPS. Change IPs in network/ips.yaml.

set -eu
export PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin

SCRIPT_DIR=$(cd "$(dirname "$0")" && pwd)
# shellcheck disable=SC1091
. "$SCRIPT_DIR/lib/core/common.sh"
case "${1:-}" in
  -h|--help) sed -n '2,/^$/p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
esac

source_envrc
require_cmd tofu ssh ssh-keygen scp jq sops age curl

INFRA_DIR="$REPO_ROOT/iac/stacks/infra"
PLATFORM_DIR="$REPO_ROOT/iac/stacks/platform"

# wait_ssh IP [TIMEOUT_SECS]
wait_ssh() {
  _ip=$1; _max=${2:-120}; _i=0
  while [ $_i -lt "$_max" ]; do
    if ssh -o BatchMode=yes -o ConnectTimeout=2 -o StrictHostKeyChecking=accept-new \
       root@"$_ip" true 2>/dev/null; then
      return 0
    fi
    sleep 2; _i=$((_i + 2))
  done
  die "$_ip not SSH-reachable after ${_max}s"
}

# ensure_apt_pkg BIN PKG — install PKG via apt if BIN is not on PATH. Idempotent.
ensure_apt_pkg() {
  command -v "$1" >/dev/null && return 0
  log_info "installing $2 (provides $1)…"
  DEBIAN_FRONTEND=noninteractive apt-get update -qq
  DEBIAN_FRONTEND=noninteractive apt-get install -y -qq "$2"
}
# Go is needed by the engines under tools/lib/cmd/ (phases 3, 4, 8).
ensure_apt_pkg go golang-go

# bootstrap_service SVC [IP] [ENV...] — emit the install script from
# services/<SVC>/bootstrap.yaml and ssh-pipe it to the target. If IP is
# omitted, defaults to $(ip_of <basename of SVC>) — works for top-level
# services with matching network/ips.yaml keys. Extra ENV args (e.g.
# "TUNNEL_TOKEN=$TUNNEL_TOKEN") are passed through to the remote shell.
bootstrap_service() {
  _svc=$1; _ip=${2:-}; shift 2 2>/dev/null || shift
  [ -n "$_ip" ] || _ip=$(awk -v want="${_svc##*/}" '
    /^services:/ { in_svc = 1; next }
    /^[^[:space:]]/ { in_svc = 0 }
    in_svc && $1 == want":" { print $2; exit }
  ' "$REPO_ROOT/network/ips.yaml")
  [ -n "$_ip" ] || die "bootstrap_service: could not resolve IP for $_svc"
  (cd "$REPO_ROOT/tools/lib" && go run ./cmd/bootstrap "$REPO_ROOT/services/$_svc/bootstrap.yaml") \
    | ssh root@"$_ip" "$* sh -s"
}

# sync_service SVC — invoke the declarative sync engine against
# services/<SVC>/sync.yaml if it exists. Caller must have already sourced
# tools/lib/infra/tofu.sh so IP_<HOST> env vars are populated.
sync_service() {
  _yaml="$REPO_ROOT/services/$1/sync.yaml"
  [ -f "$_yaml" ] || return 0
  (cd "$REPO_ROOT/tools/lib" && go run ./cmd/sync "$_yaml")
}

# ── 1. Infra ────────────────────────────────────────────────────────────────
log_step "1/8" "tofu apply — stacks/infra"
cd "$INFRA_DIR"
tofu init -input=false -upgrade=false >/dev/null
tofu apply -input=false -auto-approve

# Load IPs from tofu output now that infra state is populated.
# shellcheck disable=SC1091
. "$SCRIPT_DIR/lib/infra/tofu.sh"
log_info "IPs loaded: $ALL_LXC_IPS"

# ── 2. SSH reachability ─────────────────────────────────────────────────────
log_step "2/8" "wait for service LXCs to be SSH-reachable"
# LXCs may have been recreated with new host keys — clear stale entries.
for ip in $ALL_LXC_IPS; do
  ssh-keygen -R "$ip" >/dev/null 2>&1 || true
done
for ip in $ALL_LXC_IPS; do
  log_info "$ip"
  wait_ssh "$ip"
done

# ── 3. Per-service bootstraps ───────────────────────────────────────────────
log_step "3/8" "bootstrap service LXCs"

log_info "adguard ($IP_ADGUARD): bootstrap"
bootstrap_service adguard "$IP_ADGUARD"
sync_service adguard

log_info "gateway ($IP_GATEWAY): bootstrap (Caddy + Authelia + secrets + RSA pair)"
bootstrap_service gateway "$IP_GATEWAY"
# Authelia: argon2id hash regen is a typed pre_run hook in the sync engine
# (see authelia/sync.yaml). No shell wrapper needed.
sync_service gateway/authelia
sync_service gateway/caddy

log_info "coolify-runner-01 ($IP_RUNNER): bootstrap (Docker)"
bootstrap_service coolify-runner-01 "$IP_RUNNER"

log_info "navidrome ($IP_NAVIDROME): bootstrap"
bootstrap_service navidrome "$IP_NAVIDROME"
sync_service navidrome

log_info "lidarr ($IP_LIDARR): bootstrap (Lidarr-nightly + Tubifarry + slskd)"
bootstrap_service lidarr "$IP_LIDARR"
# sync needs SOULSEEK_USERNAME / SOULSEEK_PASSWORD in env (from sops via
# source_envrc) for slskd.yml envsubst. The sync engine will fail loudly
# if either is unset/empty.
sync_service lidarr
# configure waits for Lidarr to be HTTP-ready then POSTs the Slskd indexer
# + download client via the API (idempotent — GETs first, skips if present).
LIDARR_HOST="$IP_LIDARR" "$REPO_ROOT/services/lidarr/ops/configure.sh"

log_info "ytdl-sub ($IP_YTDL_SUB): bootstrap"
bootstrap_service ytdl-sub "$IP_YTDL_SUB"
sync_service ytdl-sub

# ── 4. Cloudflared HA pair ──────────────────────────────────────────────────
log_step "4/8" "install cloudflared connectors (Coolify + runner replica for HA)"
TUNNEL_TOKEN=$(cd "$INFRA_DIR" && tofu output -raw tunnel_token)
# Same tunnel, two connectors → 8 outbound connections across 2 LXCs.
# bootstrap_service emits the install script + ssh-pipes; we prepend
# TUNNEL_TOKEN so the FileWrite directive can read it from env.
for host in "$IP_COOLIFY" "$IP_RUNNER"; do
  log_info "cloudflared on $host"
  bootstrap_service cloudflared "$host" "TUNNEL_TOKEN=$TUNNEL_TOKEN"
done

# ── 5. Coolify (split into 3 idempotent steps for SRP) ──────────────────────
log_step "5/8" "bootstrap Coolify"
COOLIFY_HOST="$IP_COOLIFY" "$REPO_ROOT/services/coolify/ops/install.sh"
COOLIFY_HOST="$IP_COOLIFY" "$REPO_ROOT/services/coolify/ops/bootstrap-user.sh"
COOLIFY_HOST="$IP_COOLIFY" "$REPO_ROOT/services/coolify/ops/rotate-token.sh"

# rotate-token.sh wrote a new COOLIFY_API_TOKEN to sops, but it ran in its
# own subshell — its `export` doesn't reach us. Re-export from sops so the
# platform stack (phase 6) sees the fresh value via TF_VAR_coolify_api_token.
COOLIFY_API_TOKEN=$(sops -d --output-type dotenv "$REPO_ROOT/iac/secrets.sops.yaml" \
  | awk -F= '$1=="COOLIFY_API_TOKEN"{sub(/^[^=]*=/,""); print; exit}')
export COOLIFY_API_TOKEN
export TF_VAR_coolify_api_token="$COOLIFY_API_TOKEN"

# ── 6. Platform stack ───────────────────────────────────────────────────────
log_step "6/8" "tofu apply — stacks/platform (register runner in Coolify)"
cd "$PLATFORM_DIR"
tofu init -input=false -upgrade=false >/dev/null
tofu apply -input=false -auto-approve

# ── 7. Coolify-side Docker engine validation ────────────────────────────────
log_step "7/8" "trigger Coolify's Docker engine validation on runner"
# Coolify's API server-create runs validateConnection (SSH) but NOT
# validateDockerEngine. Without this, is_usable stays false until you click
# "Validate" in the UI.
ssh root@"$IP_COOLIFY" "docker exec coolify php artisan tinker --execute='
\$s = App\\Models\\Server::where(\"name\", \"coolify-runner-01\")->first();
if (\$s) { \$s->validateDockerEngine(); }
' 2>&1" | tail -3

# ── 8. Cron jobs ────────────────────────────────────────────────────────────
log_step "8/8" "sync ops LXC cron jobs (assembled from iac/cron.yaml + services/*/cron.yaml)"
TMP_CRON=$(mktemp)
trap 'rm -f "$TMP_CRON"' EXIT
(cd "$REPO_ROOT/tools/lib" && go run ./cmd/assemble-crons "$REPO_ROOT") > "$TMP_CRON"

install -d -m 0755 /etc/cron.d
if ! cmp -s "$TMP_CRON" /etc/cron.d/iac 2>/dev/null; then
  install -m 0644 "$TMP_CRON" /etc/cron.d/iac
  log_info "installed /etc/cron.d/iac"
else
  log_info "/etc/cron.d/iac up-to-date"
fi
# Pre-create log files with restrictive perms (cron creates them
# world-readable otherwise).
grep -oE '>> /var/log/[^ ]+' "$TMP_CRON" | awk '{print $2}' | sort -u | while read -r log; do
  [ -e "$log" ] || { touch "$log"; chmod 640 "$log"; }
done

# ── Summary ─────────────────────────────────────────────────────────────────
printf '\n\033[1;32m✓ apply complete — homelab converged to desired state\033[0m\n'
echo "  Coolify UI:  https://coolify.${HOMELAB_DOMAIN}"
echo "  Authelia UI: https://auth.${HOMELAB_DOMAIN}"
echo "  AdGuard UI:  https://adguard.${HOMELAB_DOMAIN} (via gateway with SSO)"
echo "  Navidrome:   https://music.${HOMELAB_DOMAIN} (via gateway with SSO)"
echo "  Lidarr:      https://lidarr.${HOMELAB_DOMAIN} (via gateway with SSO)"
echo "  slskd:       https://slskd.${HOMELAB_DOMAIN} (via gateway with SSO)"
echo "  Admin email: $HOMELAB_ADMIN_EMAIL"
echo "  Admin pass:  sops -d iac/secrets.sops.yaml | grep HOMELAB_ADMIN_PASSWORD"
