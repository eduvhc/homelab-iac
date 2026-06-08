#!/bin/sh
# Re-search every monitored album with an incomplete trackFileCount.
# Lidarr has no built-in scheduled task for this; on Soulseek the
# import success rate per first-search is low enough that the gap
# matters. See services/lidarr/cron.yaml for the schedule + rationale.
#
# Run from ops; ssh-pipes the work to the lidarr LXC.

set -eu
SCRIPT_DIR=$(cd "$(dirname "$0")" && pwd)
# shellcheck disable=SC1091
. "$SCRIPT_DIR/../../../tools/lib/core/common.sh"

require_cmd ssh

HOST=$(awk '/^services:/{f=1;next} /^[^[:space:]]/{f=0} f && $1=="lidarr:"{print $2;exit}' \
  "$REPO_ROOT/network/ips.yaml")
[ -n "$HOST" ] || die "could not resolve lidarr IP from network/ips.yaml"

# Cron fires this with no controlling tty + minimal env — be explicit.
log_info "lidarr-missing-search → $HOST"

ssh -o StrictHostKeyChecking=accept-new root@"$HOST" sh <<'REMOTE'
set -eu
. /etc/lidarr-stack/secrets.env

api() { curl -fsS -H "X-Api-Key: $LIDARR_API_KEY" "$@"; }

# Pull every (artistId, [albumIds]) tuple for albums with missing files.
# Group by artist so we issue one AlbumSearch per artist, not per album
# — Lidarr collapses these internally and the API accepts a list.
IDS_BY_ARTIST=$(api 'http://127.0.0.1:8686/api/v1/album' \
  | jq -c 'map(select(.monitored and .statistics.trackFileCount < .statistics.totalTrackCount))
           | group_by(.artistId)
           | map({artistId: .[0].artistId, ids: [.[].id]})')

count=$(echo "$IDS_BY_ARTIST" | jq 'map(.ids | length) | add // 0')
echo "$(date -u +%FT%TZ) — found $count missing album(s) across $(echo "$IDS_BY_ARTIST" | jq 'length') artist(s)"

[ "$count" = "0" ] && exit 0

echo "$IDS_BY_ARTIST" | jq -c '.[]' | while IFS= read -r group; do
  ids=$(echo "$group" | jq '.ids')
  payload=$(printf '{"name":"AlbumSearch","albumIds":%s}' "$ids")
  echo "  POST AlbumSearch ids=$ids"
  api -X POST -H 'Content-Type: application/json' \
    http://127.0.0.1:8686/api/v1/command -d "$payload" \
    | jq -r '"  → command \(.id) \(.status)"'
done
REMOTE
