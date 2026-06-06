#!/bin/sh
# Seed every BWS secret needed by iedora-iac. Idempotent — re-running only
# creates missing entries (existing ones are reported as [skip]).
#
# Rule of thumb: BWS holds genuine secrets only — values that are rotatable
# and must never appear in plaintext logs (CF/Coolify/PVE/R2 tokens, DB
# state passphrase, admin password). Identifiers + non-secret config
# (account IDs, admin name/email, org IDs) belong in iac/.envrc.
# App-runtime secrets (DB passwords, JWT secrets, AI keys for deployed
# apps) belong in the Coolify UI as env vars on the app — never here.
#
# Usage:
#   tools/seed-bws.sh [-h|--help]
#
# Bootstraps in order:
#   1. Static secrets (auto-generated or prompted)
#   2. Cloudflare R2 backend for tofu state (bucket + scoped API token)
#
# Pre-reqs:
#   - bws CLI installed, BWS_ACCESS_TOKEN exported (or /root/.bws-token present)
#   - iac/.envrc populated (BW_ORGANIZATION_ID, R2_ACCOUNT_ID, IEDORA_ADMIN_*)
#   - A BWS project named "homelab" (override with BWS_PROJECT_NAME)

set -eu

SCRIPT_DIR=$(cd "$(dirname "$0")" && pwd)
# shellcheck disable=SC1091
. "$SCRIPT_DIR/lib/common.sh"
# shellcheck disable=SC1091
. "$SCRIPT_DIR/lib/bws.sh"
# shellcheck disable=SC1091
. "$SCRIPT_DIR/lib/cloudflare.sh"

case "${1:-}" in
  -h|--help) sed -n '2,/^$/p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
esac

# Loose source (some scripts run before .envrc exists; tolerate it).
[ -f "$REPO_ROOT/iac/.envrc" ] && . "$REPO_ROOT/iac/.envrc" >/dev/null 2>&1 || true

require_cmd bws jq curl openssl
[ -n "${BWS_ACCESS_TOKEN:-${BW_ACCESS_TOKEN:-}}" ] || die "BWS_ACCESS_TOKEN not set"

PROJECT_NAME=${BWS_PROJECT_NAME:-homelab}
BWS_PROJECT_ID=$(bws_project_id_by_name "$PROJECT_NAME")
[ -n "$BWS_PROJECT_ID" ] && [ "$BWS_PROJECT_ID" != "null" ] || \
  die "BWS project '$PROJECT_NAME' not found — create it in the web UI first"
export BWS_PROJECT_ID

bws_refresh
log_info "BWS project: $PROJECT_NAME ($BWS_PROJECT_ID)"
log_info "existing: $(printf '%s' "$_BWS_CACHE" | jq -r 'map(.key) | join(", ")')"

# ── helpers ──────────────────────────────────────────────────────────────────

rand24() { openssl rand -base64 24 | tr -d '/+='; }
rand40() { openssl rand -hex 20; }

prompt() {
  printf '%s: ' "$2" >&2; read -r _v; eval "$1=\$_v"
}
prompt_secret() {
  printf '%s: ' "$2" >&2; stty -echo; read -r _v; stty echo; printf '\n' >&2
  eval "$1=\$_v"
}

# seed_secret KEY DESCRIPTION VALUE_PROVIDER…
#   VALUE_PROVIDER is a command that prints the value to stdout (e.g. `rand24`).
#   If absent in BWS, create with the provider's output; else skip.
seed_secret() {
  _key=$1; _desc=$2; shift 2
  if bws_has "$_key"; then
    printf '%-30s %s\n' "[skip] $_key" ""
    return 0
  fi
  _val=$("$@")
  bws_create "$_key" "$_val" "$_desc"
  printf '%-30s %s\n' "[new]  $_key" ""
}

# read_from_var VAR_NAME — print the named variable's value (for seed_secret).
read_from_var() { eval "printf '%s' \"\$$1\""; }

# ── 1. Static secrets ────────────────────────────────────────────────────────

echo
log_step "1/2" "static secrets"

seed_secret TOFU_STATE_PASSPHRASE \
  "OpenTofu state encryption passphrase (PBKDF2-AES-GCM). Auto-generated." \
  rand24

if ! bws_has CLOUDFLARE_API_TOKEN; then
  cat <<'EOF' >&2

Need a Cloudflare API token with these permissions on iedora.com:
  - Account / Cloudflare Tunnel : Edit
  - Account / Zero Trust        : Edit
  - Account / Cloudflare R2     : Edit   (for the tofu state bucket)
  - User    / API Tokens        : Edit   (to mint the scoped R2 token)
  - Zone    / DNS               : Edit
Create at: https://dash.cloudflare.com/profile/api-tokens
EOF
  prompt_secret CF_TOKEN_VAL "  Paste CF API token"
  seed_secret CLOUDFLARE_API_TOKEN "Cloudflare API token for tunnel + DNS + Zero Trust + R2." \
    read_from_var CF_TOKEN_VAL
else
  printf '%-30s %s\n' "[skip] CLOUDFLARE_API_TOKEN" ""
fi

if ! bws_has PVE_ROOT_PASSWORD; then
  echo >&2
  echo "Need the PVE root@pam password (set during PVE install)." >&2
  prompt_secret PVE_PASS_VAL "  PVE root password"
  seed_secret PVE_ROOT_PASSWORD \
    "PVE root@pam password (API tokens can't set LXC keyctl flag — hardcoded PVE limit)." \
    read_from_var PVE_PASS_VAL
else
  printf '%-30s %s\n' "[skip] PVE_ROOT_PASSWORD" ""
fi

seed_secret IEDORA_ADMIN_PASSWORD \
  "Admin password for Coolify + Authelia. Auto-generated — change via UIs if you want a memorable one." \
  rand24

if ! bws_has NTFY_TOPIC; then
  _topic="iedora-drift-$(rand40 | head -c 16)"
  echo "$_topic" > /tmp/_ntfy
  seed_secret NTFY_TOPIC \
    "ntfy.sh topic for IaC drift alerts. Subscribe at https://ntfy.sh/$_topic" \
    sh -c 'cat /tmp/_ntfy'
  rm -f /tmp/_ntfy
  log_info "  → Subscribe in the ntfy app at https://ntfy.sh/$_topic"
else
  printf '%-30s %s\n' "[skip] NTFY_TOPIC" ""
fi

# ── 2. Cloudflare R2 backend for tofu state ──────────────────────────────────

echo
log_step "2/2" "R2 backend (bucket + scoped API token)"

if bws_has R2_ACCESS_KEY_ID && bws_has R2_SECRET_ACCESS_KEY; then
  printf '%-30s %s\n' "[skip] R2_*" "(R2 backend already seeded)"
else
  CF_TOKEN=$(bws_get CLOUDFLARE_API_TOKEN)
  export CF_TOKEN
  [ -n "$CF_TOKEN" ] || die "CLOUDFLARE_API_TOKEN missing in BWS"

  R2_BUCKET=${R2_BUCKET:-iedora-iac-state}
  R2_LOCATION=${R2_LOCATION:-weur}

  # ACCOUNT_ID comes from iac/.envrc (non-secret identifier). Fall back to
  # discovery via CF API for first-time setup where .envrc isn't filled yet.
  ACCOUNT_ID=${R2_ACCOUNT_ID:-$(cf_account_id_for_zone iedora.com)}
  [ -n "$ACCOUNT_ID" ] || die "R2_ACCOUNT_ID not in .envrc and discovery failed — token may lack Zone:Read"
  log_info "account_id = $ACCOUNT_ID"

  # Bucket — idempotent (code 10004 = already exists).
  BUCKET_RESP=$(cf_api POST "/accounts/$ACCOUNT_ID/r2/buckets" \
    "$(jq -nc --arg b "$R2_BUCKET" --arg loc "$R2_LOCATION" \
       '{name:$b, locationHint:$loc, storageClass:"Standard"}')")
  if echo "$BUCKET_RESP" | jq -e '.success == true' >/dev/null; then
    log_info "bucket $R2_BUCKET created in $R2_LOCATION"
  elif echo "$BUCKET_RESP" | jq -e '[.errors[].code] | contains([10004])' >/dev/null 2>&1; then
    log_info "bucket $R2_BUCKET already exists — reusing"
  else
    die "failed to create R2 bucket: $BUCKET_RESP"
  fi

  # Bucket-scoped CF API token. /user/tokens (no dedicated R2 token endpoint
  # returns AWS-format creds). Conversion per CF convention:
  #   Access Key ID     = token id
  #   Secret Access Key = SHA-256 of the token value
  R2_RESOURCE="com.cloudflare.edge.r2.bucket.${ACCOUNT_ID}_default_${R2_BUCKET}"
  TOKEN_BODY=$(jq -nc --arg r "$R2_RESOURCE" '{
    name: ("iedora-iac-tofu-state-" + (now | tostring | split(".")[0])),
    policies: [{
      effect: "allow",
      permission_groups: [
        {id: "2efd5506f9c8494dacb1fa10a3e7d5b6",
         name: "Workers R2 Storage Bucket Item Write"}
      ],
      resources: { ($r): "*" }
    }]
  }')
  TOKEN_RESP=$(cf_api POST '/user/tokens' "$TOKEN_BODY")
  KEY_ID=$(echo "$TOKEN_RESP" | jq -r '.result.id // empty')
  KEY_VAL=$(echo "$TOKEN_RESP" | jq -r '.result.value // empty')
  [ -n "$KEY_ID" ] && [ -n "$KEY_VAL" ] || \
    die "failed to mint R2 API token (does CF token have 'User / API Tokens: Edit'?): $TOKEN_RESP"
  SECRET=$(printf '%s' "$KEY_VAL" | sha256sum | cut -d' ' -f1)

  bws_create R2_ACCESS_KEY_ID "$KEY_ID" \
    "R2 access key ID (bucket-scoped). Minted by seed-bws.sh."
  bws_create R2_SECRET_ACCESS_KEY "$SECRET" \
    "R2 secret access key (SHA-256 of the underlying CF API token value)."
  log_info "minted R2 token id=$KEY_ID (account_id stays in iac/.envrc, not BWS)"
fi

echo
log_info "==> seed complete. Re-run safely; existing secrets are never overwritten."
log_info "    bws secret list | jq -r '.[] | select(.key==\"<KEY>\") | .value'"
