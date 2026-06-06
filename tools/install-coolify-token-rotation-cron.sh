#!/bin/sh
# Install /etc/cron.d/coolify-token-rotation to re-mint COOLIFY_API_TOKEN
# every 25 days.
#
# The token minted by configs/coolify/scripts/bootstrap.sh expires after 30
# days. The platform tofu stack reads it via BWS. Without rotation, day 31's
# `tofu plan/apply` (or the daily drift-check) fails. We rotate at day 25 to
# leave a 5-day grace window.
#
# Run this once from the ops LXC after the first rebuild.

set -e

SCRIPT_DIR=$(cd "$(dirname "$0")" && pwd)
REPO_ROOT=${SCRIPT_DIR%/tools}

cat > /etc/cron.d/coolify-token-rotation <<EOF
# Rotate Coolify API token every 25 days at 04:00 UTC.
# See tools/install-coolify-token-rotation-cron.sh
SHELL=/bin/sh
PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin
0 4 */25 * * root $REPO_ROOT/configs/coolify/scripts/bootstrap.sh >> /var/log/coolify-token-rotation.log 2>&1
EOF
chmod 644 /etc/cron.d/coolify-token-rotation

touch /var/log/coolify-token-rotation.log
chmod 640 /var/log/coolify-token-rotation.log

echo "==> installed /etc/cron.d/coolify-token-rotation"
echo "    next run: day-of-month divisible by 25, at 04:00 UTC"
echo "    test now: $REPO_ROOT/configs/coolify/scripts/bootstrap.sh"
echo "    log:      /var/log/coolify-token-rotation.log"
