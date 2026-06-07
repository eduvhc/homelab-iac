#!/bin/bash
# Seed iac/secrets.sops.yaml. Validator-first: the operator owns the
# REQUIRED keys (filled via `sops iac/secrets.sops.yaml`); this script
# only bootstraps the file from the template, validates presence, and
# mints the AUTO-managed R2 backend creds.
#
# Usage:
#   tools/seed-secrets.sh [-h|--help]
#
# Flow:
#   1. file missing       → copy iac/secrets.template.yaml, encrypt, exit with
#                           "now fill it via sops"
#   2. REQUIRED key empty → list missing keys, exit 1
#   3. R2 creds absent    → mint via CF API, write to sops
#   4. else               → no-op (print summary)
#
# REQUIRED (operator):
#   CLOUDFLARE_API_TOKEN, PVE_ROOT_PASSWORD,
#   HOMELAB_DOMAIN, NTFY_TOPIC,
#   HOMELAB_ADMIN_NAME, HOMELAB_ADMIN_EMAIL, HOMELAB_ADMIN_PASSWORD
#
# AUTO (don't hand-edit):
#   TOFU_STATE_PASSPHRASE                   ← random, generated here
#   R2_ACCOUNT_ID                           ← derived from HOMELAB_DOMAIN
#   R2_ACCESS_KEY_ID, R2_SECRET_ACCESS_KEY  ← this script (CF API mint)
#   COOLIFY_API_TOKEN                       ← services/coolify/ops/rotate-token.sh
#
# Pre-reqs:
#   - sops + age on PATH; age private key at ~/.config/sops/age/keys.txt
#   - .sops.yaml has your age public key as a recipient

set -eu

SCRIPT_DIR=$(cd "$(dirname "$0")" && pwd)
# shellcheck disable=SC1091
. "$SCRIPT_DIR/lib/core/common.sh"
# shellcheck disable=SC1091
. "$SCRIPT_DIR/lib/secrets/sops.sh"

case "${1:-}" in
  -h|--help) sed -n '2,/^$/p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
esac

# ── Cloudflare API helper (inlined — single caller, was tools/lib/cloudflare.sh) ──
# cf_api METHOD PATH [JSON-BODY]
#   PATH is the part after https://api.cloudflare.com/client/v4 (e.g.
#   "/zones?per_page=1", "/accounts/$AID/r2/buckets"). Requires $CF_TOKEN
#   exported with the right scopes; returns response body on stdout (does
#   not validate HTTP status — callers should jq the body themselves).
cf_api() {
  : "${CF_TOKEN:?cf_api: CF_TOKEN not exported}"
  _m=$1; _p=$2; _b=${3:-}
  if [ -n "$_b" ]; then
    curl -sS -X "$_m" \
      -H "Authorization: Bearer $CF_TOKEN" \
      -H "Content-Type: application/json" \
      --data "$_b" \
      "https://api.cloudflare.com/client/v4$_p"
  else
    curl -sS -X "$_m" \
      -H "Authorization: Bearer $CF_TOKEN" \
      "https://api.cloudflare.com/client/v4$_p"
  fi
}

# cf_account_id_for_zone ZONE_NAME — return the account id that owns a zone.
cf_account_id_for_zone() {
  cf_api GET "/zones?name=$1&per_page=1" | jq -r '.result[0].account.id // empty'
}

require_cmd sops age jq curl openssl

TEMPLATE="$REPO_ROOT/iac/secrets.template.yaml"
REQUIRED="CLOUDFLARE_API_TOKEN PVE_ROOT_PASSWORD HOMELAB_DOMAIN NTFY_TOPIC HOMELAB_ADMIN_NAME HOMELAB_ADMIN_EMAIL HOMELAB_ADMIN_PASSWORD"

# ── 1. Bootstrap from template if missing ───────────────────────────────────
if [ ! -f "$SOPS_FILE" ]; then
  log_step "1/3" "creating $SOPS_FILE from template"
  [ -f "$TEMPLATE" ] || die "template missing at $TEMPLATE"
  cp "$TEMPLATE" "$SOPS_FILE"
  sops encrypt -i "$SOPS_FILE"
  echo
  log_info "Encrypted skeleton written. Now:"
  log_info "  1. sops $SOPS_FILE     # fill the REQUIRED values"
  log_info "  2. re-run $0           # validate + mint R2 backend creds"
  exit 0
fi

# ── 2. Validate REQUIRED keys are non-empty ─────────────────────────────────
log_step "2/3" "validate operator-provided keys"
missing=""
for k in $REQUIRED; do
  v=$(sops_get "$k")
  if [ -z "$v" ]; then
    missing="$missing $k"
    printf '  %-26s %s\n' "[MISSING] $k" ""
  else
    printf '  %-26s %s\n' "[ok] $k" ""
  fi
done
if [ -n "$missing" ]; then
  echo
  die "fill these via \`sops $SOPS_FILE\`:$missing"
fi

# ── 3. Auto-fill the managed keys ──────────────────────────────────────────
log_step "3/3" "auto-managed: TOFU_STATE_PASSPHRASE, R2 backend"

# TOFU_STATE_PASSPHRASE: pure plumbing (encrypts state in R2; nobody reads
# it except tofu). Generate once, persist forever — rotating means
# re-encrypting all state.
if [ -z "$(sops_get TOFU_STATE_PASSPHRASE)" ]; then
  sops_set TOFU_STATE_PASSPHRASE "$(openssl rand -base64 24 | tr -d '/+=')"
  log_info "generated TOFU_STATE_PASSPHRASE"
else
  printf '  %-26s %s\n' "[skip] TOFU_STATE_PASSPHRASE" "(already set)"
fi

CF_TOKEN=$(sops_get CLOUDFLARE_API_TOKEN); export CF_TOKEN

# R2_ACCOUNT_ID: auto-derived from HOMELAB_DOMAIN (zone owner). Needed for the
# R2 S3 endpoint URL (https://<id>.r2.cloudflarestorage.com). Tofu derives
# its own copy via the cloudflare_zone data source — not consumed via env.
if [ -z "$(sops_get R2_ACCOUNT_ID)" ]; then
  HOMELAB_DOMAIN=$(sops_get HOMELAB_DOMAIN)
  ACCOUNT_ID=$(cf_account_id_for_zone "$HOMELAB_DOMAIN")
  [ -n "$ACCOUNT_ID" ] || die "could not derive account_id for zone $HOMELAB_DOMAIN — does CF token have Zone:Read?"
  sops_set R2_ACCOUNT_ID "$ACCOUNT_ID"
  log_info "derived R2_ACCOUNT_ID=$ACCOUNT_ID from zone $HOMELAB_DOMAIN"
else
  printf '  %-26s %s\n' "[skip] R2_ACCOUNT_ID" "(already derived)"
fi

if [ -n "$(sops_get R2_ACCESS_KEY_ID)" ] && [ -n "$(sops_get R2_SECRET_ACCESS_KEY)" ]; then
  printf '  %-26s %s\n' "[skip] R2_*KEY" "(already minted)"
else
  ACCOUNT_ID=$(sops_get R2_ACCOUNT_ID)
  R2_BUCKET=${R2_BUCKET:-homelab-iac-state}
  R2_LOCATION=${R2_LOCATION:-weur}
  log_info "account_id=$ACCOUNT_ID  bucket=$R2_BUCKET  location=$R2_LOCATION"

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

  R2_RESOURCE="com.cloudflare.edge.r2.bucket.${ACCOUNT_ID}_default_${R2_BUCKET}"
  TOKEN_BODY=$(jq -nc --arg r "$R2_RESOURCE" '{
    name: ("homelab-iac-tofu-state-" + (now | tostring | split(".")[0])),
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
  log_info "minted R2 token id=$KEY_ID + saved to $SOPS_FILE"
fi

echo
log_info "==> bootstrap complete. Re-run safely; no values overwritten."
log_info "    Inspect: sops -d $SOPS_FILE"
log_info "    Edit:    sops $SOPS_FILE"
log_info "    Persist: git add iac/secrets.sops.yaml && git commit && git push"
