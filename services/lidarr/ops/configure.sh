#!/bin/sh
# Idempotently configure Lidarr's Slskd indexer + download client via API.
# Runs AFTER bootstrap (Tubifarry plugin dropped on disk) AND AFTER systemd
# starts Lidarr (so the API is reachable + Tubifarry's classes are loaded).
#
# Mirrors the UI flow at Settings → Indexers / Download Clients but skips
# the human. Schema validated against:
#   references/Tubifarry/Tubifarry/Indexers/Soulseek/SlskdSettings.cs
#   references/Tubifarry/Tubifarry/Download/Clients/Soulseek/SlskdProviderSettings.cs
#   references/Lidarr/src/Lidarr.Api.V1/Indexers/IndexerResource.cs
#
# Idempotency: GET the existing list, skip POST if an entry with the right
# implementation already exists. Safe to re-run on every apply.

set -eu
SCRIPT_DIR=$(cd "$(dirname "$0")" && pwd)
# shellcheck disable=SC1091
. "$SCRIPT_DIR/../../../tools/lib/core/common.sh"

require_cmd ssh

HOST=${LIDARR_HOST:-}
if [ -z "$HOST" ]; then
  # Fallback when called manually outside apply.sh — resolve from ips.yaml.
  HOST=$(awk '/^services:/{f=1;next} /^[^[:space:]]/{f=0} f && $1=="lidarr:"{print $2;exit}' "$REPO_ROOT/network/ips.yaml")
  [ -n "$HOST" ] || die "could not resolve lidarr IP from network/ips.yaml"
fi
log_info "configuring Lidarr at $HOST"

# All work happens on the lidarr LXC where /etc/lidarr-stack/secrets.env
# lives and localhost:8686 + localhost:5030 are reachable. Quoted heredoc
# (<<'REMOTE') means no local-side expansion — the entire script body is
# delivered verbatim and runs in the remote shell.
ssh -o StrictHostKeyChecking=accept-new root@"$HOST" sh <<'REMOTE'
set -eu

. /etc/lidarr-stack/secrets.env

# Wait for Lidarr API (up to ~120s; plugin scan can be slow on first boot).
for _i in $(seq 1 60); do
  if curl -fsS -H "X-Api-Key: $LIDARR_API_KEY" \
       http://127.0.0.1:8686/api/v1/system/status >/dev/null 2>&1; then
    break
  fi
  sleep 2
done
curl -fsS -H "X-Api-Key: $LIDARR_API_KEY" \
  http://127.0.0.1:8686/api/v1/system/status >/dev/null \
  || { echo "Lidarr API at :8686 not reachable after 120s" >&2; exit 1; }

# Confirm Tubifarry is loaded (else POST will fail with "implementation not
# found"). Lidarr exposes installed plugins at /api/v1/system/plugins.
if ! curl -fsS -H "X-Api-Key: $LIDARR_API_KEY" \
     http://127.0.0.1:8686/api/v1/system/plugins | \
     jq -e '.[] | select(.name == "Tubifarry")' >/dev/null 2>&1; then
  echo "Tubifarry plugin not loaded — check Lidarr logs (journalctl -u lidarr)" >&2
  echo "(bootstrap should have dropped it at /var/lib/lidarr/plugins/TypNull/Tubifarry/)" >&2
  exit 1
fi

api() { curl -fsS -H "X-Api-Key: $LIDARR_API_KEY" -H 'Content-Type: application/json' "$@"; }

# ── Root folder: /srv/media/music ───────────────────────────────────────────
# Where Lidarr imports completed downloads. Same FS as the slskd download
# dir (/srv/media/_incoming) → imports are rename(), not cross-device copy.
# Defaults baked into the root folder pre-fill the "Add Artist" form:
#   Quality "Lossless" (id=2) — FLAC-preferred; matches our acquisition
#                                model (Soulseek typically has FLAC)
#   Metadata "Standard" (id=1) — Lidarr's shipped default
#   Monitor "all"              — track every existing album for the artist
#   NewItemMonitor "all"       — auto-monitor newly released albums
# Schema: references/Lidarr/src/Lidarr.Api.V1/RootFolders/RootFolderResource.cs
# Enums: NzbDrone.Core.Music.{MonitorTypes,NewItemMonitorTypes}.cs
if api http://127.0.0.1:8686/api/v1/rootfolder | \
   jq -e '.[] | select(.path == "/srv/media/music")' >/dev/null; then
  echo "root folder /srv/media/music: already present (skip)"
else
  echo "root folder /srv/media/music: creating…"
  api -X POST http://127.0.0.1:8686/api/v1/rootfolder -d @- >/dev/null <<JSON
{
  "path": "/srv/media/music",
  "name": "Music",
  "defaultQualityProfileId": 2,
  "defaultMetadataProfileId": 1,
  "defaultMonitorOption": "all",
  "defaultNewItemMonitorOption": "all",
  "defaultTags": []
}
JSON
fi

# ── Indexer: Slskd ──────────────────────────────────────────────────────────
if api http://127.0.0.1:8686/api/v1/indexer | \
   jq -e '.[] | select(.implementation == "SlskdIndexer")' >/dev/null; then
  echo "indexer Slskd: already present (skip)"
else
  echo "indexer Slskd: creating…"
  api -X POST http://127.0.0.1:8686/api/v1/indexer -d @- >/dev/null <<JSON
{
  "name": "Slskd",
  "implementation": "SlskdIndexer",
  "implementationName": "Slskd",
  "configContract": "SlskdSettings",
  "enableRss": true,
  "enableAutomaticSearch": true,
  "enableInteractiveSearch": true,
  "priority": 25,
  "downloadClientId": 0,
  "fields": [
    {"name": "baseUrl",        "value": "http://127.0.0.1:5030"},
    {"name": "apiKey",         "value": "$SLSKD_API_KEY"},
    {"name": "audioFilesOnly", "value": true}
  ]
}
JSON
fi

# ── Download client: Slskd ──────────────────────────────────────────────────
if api http://127.0.0.1:8686/api/v1/downloadclient | \
   jq -e '.[] | select(.implementation == "SlskdClient")' >/dev/null; then
  echo "download client Slskd: already present (skip)"
else
  echo "download client Slskd: creating…"
  api -X POST http://127.0.0.1:8686/api/v1/downloadclient -d @- >/dev/null <<JSON
{
  "name": "Slskd",
  "implementation": "SlskdClient",
  "implementationName": "Slskd",
  "configContract": "SlskdProviderSettings",
  "enable": true,
  "priority": 1,
  "fields": [
    {"name": "baseUrl", "value": "http://127.0.0.1:5030"},
    {"name": "apiKey",  "value": "$SLSKD_API_KEY"}
  ]
}
JSON
fi

echo "lidarr configure: done"
REMOTE
