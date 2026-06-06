#!/bin/sh
# Detect drift between IaC and reality. Designed for cron.
#
# Usage:
#   tools/drift-check.sh [-h|--help]
#
# Runs `tofu plan -detailed-exitcode` against both stacks. On drift (exit 2)
# POSTs a summary to https://ntfy.sh/$NTFY_TOPIC and logs to LOG.

set -eu

SCRIPT_DIR=$(cd "$(dirname "$0")" && pwd)
# shellcheck disable=SC1091
. "$SCRIPT_DIR/lib/common.sh"

case "${1:-}" in
  -h|--help) sed -n '2,/^$/p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
esac

require_cmd tofu jq curl
source_envrc

LOG=${DRIFT_LOG:-/var/log/iac-drift.log}
NTFY_TOPIC=${NTFY_TOPIC:-}

log() {
  _ts=$(date -u '+%Y-%m-%dT%H:%M:%SZ')
  printf '[%s] %s\n' "$_ts" "$1" | tee -a "$LOG"
}

notify() {
  # args: title body priority(default 3)
  [ -n "$NTFY_TOPIC" ] || return 0
  curl -fsS \
    -H "Title: $1" -H "Priority: ${3:-3}" -H "Tags: warning,homelab" \
    -d "$2" "https://ntfy.sh/$NTFY_TOPIC" >/dev/null 2>&1 || \
    log "WARN: ntfy POST failed"
}

check_stack() {
  # args: stack-name
  _name=$1
  cd "$REPO_ROOT/iac/stacks/$_name"
  tofu init -input=false -upgrade=false >/dev/null 2>&1
  set +e
  tofu plan -input=false -detailed-exitcode -lock=false >"/tmp/drift-$_name.txt" 2>&1
  _rc=$?
  set -e
  case $_rc in
    0) log "$_name: no drift" ;;
    2)
      log "$_name: DRIFT detected"
      _summary=$(grep -E '^Plan:|will be (created|updated|destroyed|replaced)' "/tmp/drift-$_name.txt" \
        | sed -E 's/\x1b\[[0-9;]*m//g' | head -10)
      log "  $_summary"
      notify "homelab drift: $_name" "$_summary" 4
      ;;
    *)
      log "$_name: ERROR (tofu plan exit=$_rc)"
      tail -20 "/tmp/drift-$_name.txt" | sed 's/^/  /' | tee -a "$LOG"
      notify "homelab drift-check ERROR: $_name" "tofu plan exit=$_rc — see $LOG" 5
      ;;
  esac
  return $_rc
}

mkdir -p "$(dirname "$LOG")"
log "── drift-check start ──"
check_stack infra    || true
check_stack platform || true
log "── drift-check done ──"
