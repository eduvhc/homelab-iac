# shellcheck shell=sh
# Common preamble + logging helpers for every script in this repo.
#
# Usage:
#   #!/bin/sh   (or #!/bin/bash for scripts that need bashisms)
#   set -eu     (or `set -euo pipefail` in bash)
#   . "$(cd "$(dirname "$0")" && pwd)/../tools/lib/common.sh"
#
# After sourcing, the following are defined:
#   $REPO_ROOT      absolute path to the iedora-iac repo
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

# ── Repo root: works whether sourced from tools/, services/<svc>/, or
# services/<svc>/<sub>/. Relies on $0 being the calling script. ──────────────
_COMMON_DIR=$(cd "$(dirname "$0")" 2>/dev/null && pwd)
REPO_ROOT=${_COMMON_DIR%/tools*}
REPO_ROOT=${REPO_ROOT%/services*}
export REPO_ROOT
unset _COMMON_DIR

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

# source_envrc — source iac/.envrc (which exports sops-decrypted secrets +
# R2 backend vars + identifiers) once.
# Idempotent: subsequent calls are no-ops within the same shell.
source_envrc() {
  [ "${_ENVRC_SOURCED:-0}" = "1" ] && return 0
  [ -f "$REPO_ROOT/iac/.envrc" ] || die "iac/.envrc not found — copy from iac/.envrc.example"
  # shellcheck disable=SC1091
  . "$REPO_ROOT/iac/.envrc"
  _ENVRC_SOURCED=1
}
