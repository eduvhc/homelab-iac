#!/bin/sh
# Detect drift between IaC and reality. Designed for cron.
#
# Runs `tofu plan -detailed-exitcode` against both stacks. Exit codes:
#   0  no changes
#   1  error
#   2  drift detected (changes pending)
#
# On drift (exit 2), POSTs a summary to https://ntfy.sh/$NTFY_TOPIC and
# appends to /var/log/iac-drift.log. NTFY_TOPIC is read from BWS.
#
# Tests at the end ensure the cron entry actually fires this script daily.

set -e

# Cron-safe PATH (bws + tofu live in /usr/local/bin)
export PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin

SCRIPT_DIR=$(cd "$(dirname "$0")" && pwd)
REPO_ROOT=${SCRIPT_DIR%/tools}
# shellcheck disable=SC1091
. "$REPO_ROOT/iac/.envrc"

LOG=/var/log/iac-drift.log
NTFY_TOPIC=$(bws secret list --output json 2>/dev/null | \
  jq -r '.[] | select(.key=="NTFY_TOPIC") | .value')

log() {
  ts=$(date -u '+%Y-%m-%dT%H:%M:%SZ')
  printf '[%s] %s\n' "$ts" "$1" | tee -a "$LOG"
}

notify() {
  # args: title body priority(default 3)
  title=$1; body=$2; prio=${3:-3}
  if [ -n "$NTFY_TOPIC" ] && [ "$NTFY_TOPIC" != "null" ]; then
    curl -fsS \
      -H "Title: $title" \
      -H "Priority: $prio" \
      -H "Tags: warning,iedora" \
      -d "$body" \
      "https://ntfy.sh/$NTFY_TOPIC" >/dev/null 2>&1 || \
      log "WARN: ntfy POST failed"
  fi
}

check_stack() {
  # args: stack-dir-relative human-name
  rel=$1; name=$2
  cd "$REPO_ROOT/iac/stacks/$rel"
  tofu init -input=false -upgrade=false >/dev/null 2>&1
  if tofu plan -input=false -detailed-exitcode -lock=false >/tmp/drift-$name.txt 2>&1; then
    rc=$?
  else
    rc=$?
  fi
  case $rc in
    0) log "$name: no drift" ;;
    2)
      log "$name: DRIFT detected"
      # Extract the resource-change summary line for the notification body.
      # Strip ANSI color codes that tofu emits even with non-TTY stdout.
      summary=$(grep -E '^Plan:|will be (created|updated|destroyed|replaced)' /tmp/drift-$name.txt \
        | sed -E 's/\x1b\[[0-9;]*m//g' | head -10)
      log "  $summary"
      notify "iedora drift: $name" "$summary" 4
      ;;
    *)
      log "$name: ERROR (tofu plan exit=$rc)"
      tail -20 /tmp/drift-$name.txt | sed 's/^/  /' | tee -a "$LOG"
      notify "iedora drift-check ERROR: $name" "tofu plan exit=$rc — see $LOG" 5
      ;;
  esac
  return $rc
}

mkdir -p "$(dirname "$LOG")"
log "── drift-check start ──"
check_stack infra    infra    || true
check_stack platform platform || true
log "── drift-check done ──"
