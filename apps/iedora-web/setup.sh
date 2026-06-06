#!/bin/bash
# Ensure the `iedora-web` Coolify app + its Postgres exist and match this spec.
# Idempotent: re-running only patches drift; existing resources are reused.
#
# Pre-reqs:
#   - iac/.envrc sourced (provides $COOLIFY_API_TOKEN via sops)
#   - SSH access to the runner LXC (for the postgres init script)
#
# Secrets policy (3-tier rule, see README):
#   This script manages plain env vars + computed DATABASE_URLs only.
#   App-runtime secrets (CORE_SECRET, DEEPSEEK_API_KEY, S3_*, etc.) live
#   in the Coolify UI as env vars on the app — set them there once.

set -euo pipefail

SCRIPT_DIR=$(cd "$(dirname "$0")" && pwd)
# shellcheck disable=SC1091
. "$SCRIPT_DIR/../../tools/lib/common.sh"

source_envrc
require_cmd curl jq ssh

# ── Config ──────────────────────────────────────────────────────────────────
COOLIFY_URL=${COOLIFY_URL:-https://coolify.iedora.com}
PROJECT_NAME=iedora
POSTGRES_NAME=iedora-pg
APP_NAME=iedora-web
APP_REPO=https://github.com/eduvhc/iedora
APP_BRANCH=main
APP_DOCKERFILE=/apps/web/Dockerfile
APP_PORT=3000
APP_HEALTHCHECK=/up
APP_DOMAINS=https://iedora.com,https://menu.iedora.com,https://core.iedora.com,https://imopush.iedora.com
DATABASES=(core menu imopush)
PRE_DEPLOY='sh -c "node /app/packages/business/auth/migrate.mjs && node /app/products/menu/migrate.mjs && node /app/products/imopush/migrate.mjs"'

# Coolify API token format: "<id>|<plain>". The Authorization header uses
# the whole thing (Sanctum strips id prefix server-side).
TOKEN=${COOLIFY_API_TOKEN:?must be set in iac/secrets.sops.yaml}

# Runner UUID — the server where Coolify deploys things. Fetched once.
RUNNER_UUID=$(curl -fsS -H "Authorization: Bearer $TOKEN" "$COOLIFY_URL/api/v1/servers" \
  | jq -r '.[] | select(.name=="coolify-runner-01") | .uuid')
[ -n "$RUNNER_UUID" ] || die "coolify-runner-01 not registered in Coolify"

# ── helpers ────────────────────────────────────────────────────────────────
api() { curl -fsS -H "Authorization: Bearer $TOKEN" -H "Content-Type: application/json" "$@"; }

# ── 1. Project ─────────────────────────────────────────────────────────────
log_step "1/4" "project: $PROJECT_NAME"
PROJECT_UUID=$(api "$COOLIFY_URL/api/v1/projects" | jq -r ".[] | select(.name==\"$PROJECT_NAME\") | .uuid" | head -1)
if [ -z "$PROJECT_UUID" ]; then
  PROJECT_UUID=$(api -X POST "$COOLIFY_URL/api/v1/projects" \
    -d "$(jq -nc --arg n "$PROJECT_NAME" '{name:$n, description:"iedora monorepo - Nextjs + Postgres"}')" \
    | jq -r .uuid)
  log_info "created project uuid=$PROJECT_UUID"
else
  log_info "project exists uuid=$PROJECT_UUID"
fi

# ── 2. Postgres + 3 DBs ────────────────────────────────────────────────────
log_step "2/4" "postgres: $POSTGRES_NAME"
# Coolify's list endpoint for DBs is /databases; filter by name + project.
PG_UUID=$(api "$COOLIFY_URL/api/v1/databases" \
  | jq -r ".[] | select(.name==\"$POSTGRES_NAME\") | .uuid" | head -1)
PG_PW=""
if [ -z "$PG_UUID" ]; then
  PG_PW=$(openssl rand -base64 24 | tr -d '+/=' | head -c 24)
  RESP=$(api -X POST "$COOLIFY_URL/api/v1/databases/postgresql" \
    -d "$(jq -nc --arg pw "$PG_PW" --arg p "$PROJECT_UUID" --arg s "$RUNNER_UUID" --arg n "$POSTGRES_NAME" '{
      project_uuid:$p, environment_name:"production", server_uuid:$s,
      name:$n, description:"Postgres 18 - 3 DBs core menu imopush",
      image:"postgres:18", postgres_user:"postgres",
      postgres_password:$pw, postgres_db:"postgres", instant_deploy:true
    }')")
  PG_UUID=$(echo "$RESP" | jq -r .uuid)
  log_info "created postgres uuid=$PG_UUID — waiting for health"
  for _ in $(seq 1 30); do
    s=$(api "$COOLIFY_URL/api/v1/databases/$PG_UUID" | jq -r .status)
    [ "$s" = "running:healthy" ] && break
    sleep 4
  done
  # Boot the 3 app DBs (idempotent: skip if exist).
  for db in "${DATABASES[@]}"; do
    ssh -o StrictHostKeyChecking=accept-new root@192.168.50.210 \
      "docker exec -e PGPASSWORD='$PG_PW' '$PG_UUID' \
        psql -U postgres -tAc \"SELECT 1 FROM pg_database WHERE datname='$db'\" \
        | grep -q 1 || docker exec -e PGPASSWORD='$PG_PW' '$PG_UUID' \
        psql -U postgres -c 'CREATE DATABASE $db'"
  done
  log_info "created databases: ${DATABASES[*]}"
else
  log_info "postgres exists uuid=$PG_UUID (assuming password unchanged — secrets stay in Coolify UI)"
fi

# ── 3. Application ─────────────────────────────────────────────────────────
log_step "3/4" "application: $APP_NAME"
APP_UUID=$(api "$COOLIFY_URL/api/v1/applications" \
  | jq -r ".[] | select(.name==\"$APP_NAME\") | .uuid" | head -1)
if [ -z "$APP_UUID" ]; then
  RESP=$(api -X POST "$COOLIFY_URL/api/v1/applications/public" \
    -d "$(jq -nc --arg p "$PROJECT_UUID" --arg s "$RUNNER_UUID" --arg n "$APP_NAME" \
              --arg repo "$APP_REPO" --arg br "$APP_BRANCH" --arg df "$APP_DOCKERFILE" \
              --arg port "$APP_PORT" --arg hc "$APP_HEALTHCHECK" --arg dom "$APP_DOMAINS" '{
      project_uuid:$p, environment_name:"production", server_uuid:$s,
      name:$n, description:"Next.js multi-host app",
      git_repository:$repo, git_branch:$br, build_pack:"dockerfile",
      dockerfile_location:$df, base_directory:"/",
      ports_exposes:$port, health_check_enabled:true,
      health_check_path:$hc, health_check_port:$port,
      domains:$dom, instant_deploy:false
    }')")
  APP_UUID=$(echo "$RESP" | jq -r .uuid)
  log_info "created application uuid=$APP_UUID"
else
  log_info "application exists uuid=$APP_UUID"
fi

# Always patch top-level config (idempotent — Coolify diffs internally).
api -X PATCH "$COOLIFY_URL/api/v1/applications/$APP_UUID" \
  -d "$(jq -nc --arg cmd "$PRE_DEPLOY" '{
    pre_deployment_command: $cmd,
    pre_deployment_command_container: "iedora-web",
    is_auto_deploy_enabled: true,
    is_force_https_enabled: true
  }')" >/dev/null
log_info "patched app config (pre-deploy, auto-deploy, https)"

# ── 4. Env vars ────────────────────────────────────────────────────────────
log_step "4/4" "env vars (plain only — secrets stay manual in Coolify UI)"

# Build the connection strings if we just generated the pw (else they exist).
if [ -n "$PG_PW" ]; then
  for db in "${DATABASES[@]}"; do
    upper=$(echo "$db" | tr '[:lower:]' '[:upper:]')
    eval "${upper}_DATABASE_URL='postgresql://postgres:${PG_PW}@${PG_UUID}:5432/${db}'"
  done
fi

# PATCH idempotently upserts by key. Plain values only — never secrets.
patch_env() {
  api -X PATCH "$COOLIFY_URL/api/v1/applications/$APP_UUID/envs" \
    -d "$(jq -nc --arg k "$1" --arg v "$2" '{key:$k, value:$v}')" >/dev/null
  printf '  ok  %s\n' "$1"
}

patch_env NODE_ENV "production"
patch_env CORE_BASE_URL "https://core.iedora.com"
patch_env CORE_COOKIE_DOMAIN ".iedora.com"
patch_env CORE_TRUSTED_ORIGINS "https://iedora.com,https://menu.iedora.com,https://core.iedora.com"
patch_env NEXT_PUBLIC_CORE_URL "https://core.iedora.com"
patch_env NEXT_PUBLIC_MENU_URL "https://menu.iedora.com"
patch_env NEXT_PUBLIC_IMOPUSH_URL "https://imopush.iedora.com"
patch_env NEXT_PUBLIC_BRAND_URL "https://iedora.com"
patch_env IEDORA_BOOTSTRAP_ADMIN_EMAILS "$IEDORA_ADMIN_EMAIL"
patch_env LOG_LEVEL "info"

# Database URLs: only patch on first create (we have the password).
# On re-runs, the existing values in Coolify already work — don't touch.
if [ -n "$PG_PW" ]; then
  patch_env CORE_DATABASE_URL "$CORE_DATABASE_URL"
  patch_env MENU_DATABASE_URL "$MENU_DATABASE_URL"
  patch_env IMOPUSH_DATABASE_URL "$IMOPUSH_DATABASE_URL"
fi

# Sanity check: warn if known-required app secrets are missing in Coolify.
EXISTING=$(api "$COOLIFY_URL/api/v1/applications/$APP_UUID/envs" | jq -r '.[].key')
for k in CORE_SECRET S3_ACCESS_KEY S3_SECRET_KEY S3_BUCKET S3_ENDPOINT S3_REGION DEEPSEEK_API_KEY MOONSHOT_API_KEY; do
  if ! echo "$EXISTING" | grep -qx "$k"; then
    log_warn "  missing app secret: $k — set it manually in Coolify UI"
  fi
done

echo
log_info "==> done. App: $COOLIFY_URL/project/$PROJECT_UUID/environment/production/application/$APP_UUID"
log_info "    First deploy: hit Deploy in the UI, or:"
log_info "      curl -H \"Authorization: Bearer \$COOLIFY_API_TOKEN\" \\"
log_info "        \"$COOLIFY_URL/api/v1/deploy?uuid=$APP_UUID&force=false\""
