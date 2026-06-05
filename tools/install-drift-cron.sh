#!/bin/sh
# Install /etc/cron.d/iac-drift to run drift-check.sh daily at 06:30 UTC.
# Run this once from the ops LXC after the repo is cloned.

set -e

SCRIPT_DIR=$(cd "$(dirname "$0")" && pwd)
REPO_ROOT=${SCRIPT_DIR%/tools}

cat > /etc/cron.d/iac-drift <<EOF
# Daily IaC drift detection — see tools/drift-check.sh
SHELL=/bin/sh
PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin
30 6 * * * root $REPO_ROOT/tools/drift-check.sh >> /var/log/iac-drift.log 2>&1
EOF
chmod 644 /etc/cron.d/iac-drift

touch /var/log/iac-drift.log
chmod 640 /var/log/iac-drift.log

echo "==> installed /etc/cron.d/iac-drift"
echo "    next run: tomorrow 06:30 UTC"
echo "    test now: $REPO_ROOT/tools/drift-check.sh"
echo "    log:      /var/log/iac-drift.log"
