#!/bin/sh
# Inner backup of Coolify's source PostgreSQL DB (the `coolify` DB inside
# the `coolify-db` container). Writes a custom-format pg_dump to the
# Coolify host's rootfs so the next vzdump snapshot captures it.
#
# Why "inner": vzdump alone snapshots Postgres while it's serving
# writes; the snapshot is filesystem-consistent but a SQLite-equivalent
# WAL recovery is not what Postgres needs. pg_dump produces a logically
# consistent, restore-anywhere file. See docs/backups.md for the
# "Per-service exceptions" rationale.
#
# Runs from ops via cron (services/coolify/cron.yaml). Pattern shared
# with future services: see tools/backups/lib/postgres.sh + retention.sh.

set -eu

SCRIPT_DIR=$(cd "$(dirname "$0")" && pwd)
REPO_ROOT=${SCRIPT_DIR%/services/*}
export REPO_ROOT
# shellcheck disable=SC1091
. "$REPO_ROOT/tools/lib/common.sh"
# shellcheck disable=SC1091
. "$REPO_ROOT/tools/backups/lib/postgres.sh"
# shellcheck disable=SC1091
. "$REPO_ROOT/tools/backups/lib/retention.sh"

# Coolify host IP is stable per network/ips.yaml; we don't need the full
# tofu output round-trip here (cron runs many times per week and tofu
# output adds 1-2s + a state read). Reading the YAML directly is enough.
HOST=root@$(awk '/^  coolify:/ {print $2}' "$REPO_ROOT/network/ips.yaml")
[ -n "${HOST#root@}" ] || die "could not resolve coolify IP from network/ips.yaml"

DEST_DIR=/data/coolify/backups/source
LABEL=coolify-source
KEEP=14

log_info "coolify pg_dump → $HOST:$DEST_DIR (keep last $KEEP)"
pg_dump_in_container "$HOST" coolify-db coolify coolify "$DEST_DIR" "$LABEL"
rotate_keep_last     "$HOST" "$DEST_DIR" "$LABEL-*.dmp" "$KEEP"
log_info "coolify pg_dump: done"
