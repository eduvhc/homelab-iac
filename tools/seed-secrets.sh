#!/bin/sh
# Seed every secret needed by iedora-iac into iac/secrets.sops.yaml.
# Idempotent — re-running only fills missing entries; existing ones are
# reported as [skip] and never overwritten.
#
# Boundary:
#   - secrets.sops.yaml = rotatable platform secrets, encrypted with age
#   - iac/.envrc        = identifiers + non-secret config (R2_ACCOUNT_ID,
#                         IEDORA_ADMIN_NAME/EMAIL, NTFY_TOPIC)
#   - Coolify UI        = app-runtime secrets (per deployed app) — not here
#
# Usage:
#   tools/seed-secrets.sh [-h|--help]
#
# Bootstraps in order:
#   1. Static secrets (auto-generated or prompted into encrypted yaml)
#   2. Cloudflare R2 backend for tofu state (bucket + scoped API token)
#
# Pre-reqs:
#   - sops + age on PATH; age private key at ~/.config/sops/age/keys.txt
#   - iac/.envrc populated (R2_ACCOUNT_ID etc.) — needed for R2 endpoint
#   - On first run, iac/secrets.sops.yaml is created from scratch.

set -eu

SCRIPT_DIR=$(cd "$(dirname "$0")" && pwd)
# shellcheck disable=SC1091
. "$SCRIPT_DIR/lib/common.sh"
# shellcheck disable=SC1091
. "$SCRIPT_DIR/lib/sops.sh"
# shellcheck disable=SC1091
. "$SCRIPT_DIR/lib/cloudflare.sh"

case "${1:-}" in
  -h|--help) sed -n '2,/^$/p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
esac

# Loose source (some scripts run before .envrc exists; tolerate it).
[ -f "$REPO_ROOT/iac/.envrc" ] && . "$REPO_ROOT/iac/.envrc" >/dev/null 2>&1 || true

require_cmd sops age jq curl openssl

# Ensure the encrypted file exists; create a minimal one if missing so that
# subsequent sops_set calls have a target.
if [ ! -f "$SOPS_FILE" ]; then
  log_info "creating fresh $SOPS_FILE"
  printf '# Created by tools/seed-secrets.sh on %s\n_placeholder: x\n' \
    "$(date -u +%Y-%m-%dT%H:%M:%SZ)" > "$SOPS_FILE"
  sops encrypt -i "$SOPS_FILE"
fi

# ── helpers ──────────────────────────────────────────────────────────────────

rand24() { openssl rand -base64 24 | tr -d '/+='; }
rand40() { openssl rand -hex 20; }

prompt_secret() {
  printf '%s: ' "$2" >&2; stty -echo; read -r _v; stty echo; printf '\n' >&2
  eval "$1=\$_v"
}

# seed_secret KEY DESCRIPTION VALUE_PROVIDER…
#   VALUE_PROVIDER is a command that prints the value to stdout (e.g. `rand24`).
#   If absent in sops file, create with the provider's output; else skip.
seed_secret() {
  _key=$1; _desc=$2; shift 2
  if sops_has "$_key"; then
    printf '%-30s %s\n' "[skip] $_key" ""
    return 0
  fi
  _val=$("$@")
  sops_set "$_key" "$_val"
  printf '%-30s %s\n' "[new]  $_key" "($_desc)"
}

# read_from_var VAR_NAME — print the named variable's value (for seed_secret).
read_from_var() { eval "printf '%s' \"\$$1\""; }

# ── 1. Static secrets ────────────────────────────────────────────────────────

echo
log_step "1/2" "static secrets"

seed_secret TOFU_STATE_PASSPHRASE \
  "OpenTofu state encryption passphrase (PBKDF2-AES-GCM)" \
  rand24

if ! sops_has CLOUDFLARE_API_TOKEN; then
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
  seed_secret CLOUDFLARE_API_TOKEN "CF API token for tunnel + DNS + R2" \
    read_from_var CF_TOKEN_VAL
else
  printf '%-30s %s\n' "[skip] CLOUDFLARE_API_TOKEN" ""
fi

if ! sops_has PVE_ROOT_PASSWORD; then
  echo >&2
  echo "Need the PVE root@pam password (set during PVE install)." >&2
  prompt_secret PVE_PASS_VAL "  PVE root password"
  seed_secret PVE_ROOT_PASSWORD "PVE root@pam password" read_from_var PVE_PASS_VAL
else
  printf '%-30s %s\n' "[skip] PVE_ROOT_PASSWORD" ""
fi

seed_secret IEDORA_ADMIN_PASSWORD \
  "Bootstrap admin password for Coolify + Authelia. Change in UI after first login." \
  rand24

# NTFY_TOPIC is not a secret — print one if NTFY_TOPIC isn't already set in
# iac/.envrc, so operator can paste it there.
if [ -z "${NTFY_TOPIC:-}" ]; then
  _topic="iedora-drift-$(rand40 | head -c 16)"
  log_info "NTFY_TOPIC unset in .envrc — suggested value:"
  log_info "  export NTFY_TOPIC=\"$_topic\""
  log_info "  → also subscribe on phone at https://ntfy.sh/$_topic"
fi

# ── 2. Cloudflare R2 backend for tofu state ──────────────────────────────────

echo
log_step "2/2" "R2 backend (bucket + scoped API token)"

if sops_has R2_ACCESS_KEY_ID && sops_has R2_SECRET_ACCESS_KEY; then
  printf '%-30s %s\n' "[skip] R2_*" "(R2 backend already seeded)"
else
  CF_TOKEN=$(sops_get CLOUDFLARE_API_TOKEN)
  export CF_TOKEN
  [ -n "$CF_TOKEN" ] || die "CLOUDFLARE_API_TOKEN missing from $SOPS_FILE"

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

  # Bucket-scoped CF API token, converted to S3-compat creds per CF convention:
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

  sops_set R2_ACCESS_KEY_ID "$KEY_ID"
  sops_set R2_SECRET_ACCESS_KEY "$SECRET"
  log_info "minted R2 token id=$KEY_ID + saved 2 secrets to $SOPS_FILE"
fi

echo
log_info "==> seed complete. Re-run safely; existing secrets are never overwritten."
log_info "    Inspect: sops -d $SOPS_FILE"
log_info "    Edit:    sops $SOPS_FILE"
log_info "    Persist: git add iac/secrets.sops.yaml && git commit && git push"
