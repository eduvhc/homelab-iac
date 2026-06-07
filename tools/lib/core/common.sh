# shellcheck shell=sh
# Common preamble + logging helpers for every script in this repo.
#
# Usage:
#   #!/bin/sh   (or #!/bin/bash for scripts that need bashisms)
#   set -eu     (or `set -euo pipefail` in bash)
#   . "$(cd "$(dirname "$0")" && pwd)/../tools/lib/core/common.sh"
#
# After sourcing, the following are defined:
#   $REPO_ROOT      absolute path to the homelab-iac repo
#   log_info ...    informational (stdout, dim gray)
#   log_step N/T m  numbered step (stdout, bright blue)
#   log_warn ...    warning (stderr, yellow)
#   log_err  ...    error   (stderr, red)
#   die [code] ...  print error then exit (default code: 1)
#   require_cmd ... fail with a friendly message if any cmd is missing
#
# Behavior knobs (env vars):
#   TRACE=1         enable `set -x` for debugging
#   NO_COLOR=1      disable ANSI colors in log output

# ── Strict mode (caller already set -e/-u; we add pipefail when in bash) ──────
# Note: POSIX sh doesn't have `set -o pipefail`. Bash, ksh, zsh do.
# shellcheck disable=SC3040
(set -o pipefail 2>/dev/null) && set -o pipefail || true

# Optional xtrace via env (debugging without editing the script).
[ "${TRACE:-0}" = "1" ] && set -x

# ── Repo root: derive from $0 when sourced by a script in tools/, services/,
# or apps/. Cross-repo consumers (an app repo's infra/tofu/.envrc) pre-set
# REPO_ROOT to point at this repo's root before sourcing; honour that. ───────
if [ -z "${REPO_ROOT:-}" ]; then
  _COMMON_DIR=$(cd "$(dirname "$0")" 2>/dev/null && pwd)
  REPO_ROOT=${_COMMON_DIR%/tools*}
  REPO_ROOT=${REPO_ROOT%/services*}
  REPO_ROOT=${REPO_ROOT%/apps*}
  unset _COMMON_DIR
fi
export REPO_ROOT

# ── Logging ──────────────────────────────────────────────────────────────────
if [ -t 2 ] && [ "${NO_COLOR:-0}" != "1" ]; then
  _C_INFO='\033[0;90m';  _C_STEP='\033[1;34m'
  _C_WARN='\033[0;33m';  _C_ERR='\033[1;31m'
  _C_RESET='\033[0m'
else
  _C_INFO=''; _C_STEP=''; _C_WARN=''; _C_ERR=''; _C_RESET=''
fi

log_info() { printf '%b  %s%b\n'   "$_C_INFO" "$*" "$_C_RESET"; }
log_step() { printf '\n%b[%s]%b %s\n' "$_C_STEP" "$1" "$_C_RESET" "$2"; }
log_warn() { printf '%bwarn:%b %s\n' "$_C_WARN" "$_C_RESET" "$*" >&2; }
log_err()  { printf '%berror:%b %s\n' "$_C_ERR"  "$_C_RESET" "$*" >&2; }

# die [exit-code] msg…
die() {
  case $1 in
    ''|*[!0-9]*) _code=1 ;;
    *)           _code=$1; shift ;;
  esac
  log_err "$*"
  exit "$_code"
}

# require_cmd cmd [cmd…] — fail with one consolidated message if any missing.
require_cmd() {
  _missing=
  for _c; do command -v "$_c" >/dev/null 2>&1 || _missing="$_missing $_c"; done
  [ -z "$_missing" ] || die "missing required command(s):$_missing"
}

# source_envrc — decrypt iac/secrets.sops.yaml and export all 11 keys
# (secrets + identifiers) into the environment, then apply adapter mappings
# (TF_VAR_* for tofu, AWS_* for the R2 s3 backend). Single source of truth.
# Idempotent: subsequent calls are no-ops within the same shell.
#
# Pre-reqs: sops + age on PATH; age private key at ~/.config/sops/age/keys.txt.
# POSIX-clean (works under dash / Debian /bin/sh).
source_envrc() {
  [ "${_ENVRC_SOURCED:-0}" = "1" ] && return 0
  [ -f "$REPO_ROOT/iac/secrets.sops.yaml" ] || die "iac/secrets.sops.yaml not found"

  # Decrypt the dotenv view into a temp file and read line-by-line. We
  # don't `. "$file"` because sops's dotenv output is unquoted, so values
  # containing shell metacharacters (e.g. COOLIFY_API_TOKEN = "id|token")
  # would be interpreted as pipelines. The read/export loop treats every
  # value as a literal string.
  _envrc_tmp=$(mktemp)
  sops -d --output-type dotenv "$REPO_ROOT/iac/secrets.sops.yaml" > "$_envrc_tmp"
  while IFS='=' read -r _k _v; do
    [ -n "$_k" ] && [ "${_k#\#}" = "$_k" ] && export "$_k=$_v"
  done < "$_envrc_tmp"
  rm -f "$_envrc_tmp"
  unset _envrc_tmp _k _v

  # Adapter: tofu variable names (TF_VAR_x → `variable "x" {}` blocks).
  # Use ${VAR:-} so this survives `set -u` even mid-bootstrap when some
  # keys may not yet be seeded; downstream tofu/aws will surface a clearer
  # error than "unbound variable" from this layer.
  export TF_VAR_tf_state_passphrase="${TOFU_STATE_PASSPHRASE:-}"
  export TF_VAR_cf_api_token="${CLOUDFLARE_API_TOKEN:-}"
  export TF_VAR_pve_root_password="${PVE_ROOT_PASSWORD:-}"
  export TF_VAR_coolify_api_token="${COOLIFY_API_TOKEN:-}"
  export TF_VAR_domain="${HOMELAB_DOMAIN:-}"

  # R2 backend for tofu state (S3-compat; AWS_* are what the s3 backend reads).
  # account_id in the endpoint is mandatory per CF docs — no S3-style host
  # without it.
  export AWS_ACCESS_KEY_ID="${R2_ACCESS_KEY_ID:-}"
  export AWS_SECRET_ACCESS_KEY="${R2_SECRET_ACCESS_KEY:-}"
  export AWS_REGION=auto
  export AWS_ENDPOINT_URL_S3="https://${R2_ACCOUNT_ID:-}.r2.cloudflarestorage.com"

  _ENVRC_SOURCED=1
}
