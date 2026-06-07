# Media stack

How music acquisition + serving fit together. Three LXCs share a single
host directory `/srv/media` (HDD, 1.8 TB, label `media`). Storage details
in [`backups.md`](backups.md) → `### Physical disks → sdb`.

## Data flow

```
 ┌──────────────────┐  watchlist   ┌──────────────────┐  Soulseek search
 │  Lidarr (105)    │ ───────────► │  soularr (105)   │ ───────┐
 │  /artists/wanted │              │  10-min timer    │        ▼
 └────────▲─────────┘              └──────────────────┘  ┌──────────────────┐
          │                                              │  slskd (105)     │
          │ import (rename, same FS)                     │  Soulseek peer   │
          │                                              └────────┬─────────┘
          │                                                       │ FLAC/MP3
          │                                                       ▼
 ┌────────┴──────────────────────────────────────────────────────────────────┐
 │  /srv/media/_incoming  (slskd downloads)                                  │
 │  /srv/media/music      (Lidarr-managed library, FLAC preferred)           │
 │  /srv/media/youtube    (ytdl-sub-managed, daily)                          │
 └─────────────────────────────────────────▲─────────────────────────────────┘
                                           │ read
                                           │
                                  ┌────────┴──────────┐
                                  │  Navidrome (104)  │
                                  │  OpenSubsonic API │
                                  └───────────────────┘
```

```
                       ┌─────────────────┐  daily 04:00
                       │  ytdl-sub (106) │ ─── YouTube → /srv/media/youtube
                       │  timer-driven   │
                       └─────────────────┘
```

## Why this shape

- **One physical disk, three writers.** sdb (SMR HDD) is fine for media
  because writes are sequential and sparse: Lidarr finishes one album at
  a time; ytdl-sub runs once per day. The SMR caveat that retired sdb
  from vzdump duty (concurrent random writes) doesn't apply here.
- **Bind mount, not NFS.** Same PVE node → host path bind into each LXC.
  Zero network in the path. Permissions via a shared `media` group
  (GID 65000 → host 165000 via unprivileged-LXC subuid mapping).
- **Lidarr orchestrates only.** Tidal was considered but skipped — AAC
  via plan normal is lower quality than Soulseek FLAC for the same
  album. Revisit if/when upgrading to HiFi.
- **YouTube parallel to Lidarr.** Lidarr's mental model is "monitor
  artist discographies"; YouTube content (mixes, sets, lives) doesn't
  fit that. ytdl-sub stays independent, declarative via
  `services/ytdl-sub/target/subscriptions.yaml`.

## Host setup (one-time, BEFORE first apply)

The PVE host must have `/srv/media` mounted and pre-permissioned
before the LXCs bind into it. This is **imperative state on the
host** — not in tofu (same as the `backup` storage pool; see
`backups.md` → "Known gaps").

### 1. Mount the disk (sdb1 today)

```bash
# On the PVE host. Skip if already mounted — check first with: mount | grep /srv/media
mkfs.ext4 -L media /dev/sdb1                            # fresh disks only
mkdir -p /srv/media
UUID=$(blkid -s UUID -o value /dev/sdb1)
echo "UUID=${UUID}  /srv/media  ext4  defaults,nofail  0 2" >> /etc/fstab
mount /srv/media
```

`nofail` is critical — without it, a transient USB disk hiccup at
boot leaves the PVE host stuck in emergency mode.

### 2. Pre-create the subdir layout with the right unprivileged-LXC perms

```bash
# On the PVE host.
install -d -o 100000 -g 165000 -m 2775 \
  /srv/media/music \
  /srv/media/youtube \
  /srv/media/_incoming
```

The numbers explained:
- `100000` = the unprivileged-LXC root user (UID 0 inside → 100000
  on host via `/etc/subuid: root:100000:65536`).
- `165000` = the **media group** (GID 65000 inside any LXC → 165000
  on host via `/etc/subgid: root:100000:65536`).
- `2775` = setgid + group-writable. setgid ensures new files inherit
  the parent's group, so cross-LXC writes stay group-readable
  (Lidarr writes a FLAC; Navidrome reads it).

**The host doesn't need a Unix group named `media`** — only the GID
165000 matters. The label `media` is the group name **inside** each
container (declared via `groups: [{name: media, gid: 65000}]` in
each `services/<svc>/bootstrap.yaml`).

### 3. Verify before applying

```bash
ls -ld /srv/media/{music,youtube,_incoming}
# All three should show:  drwxrwsr-x  100000:165000
```

If any subdir is owned by a different UID/GID (e.g. `100999:100991`
left over from a previous container's `install -d`), fix it:

```bash
chown -R 100000:165000 /srv/media/<wrong-dir>
find /srv/media/<wrong-dir> -type d -exec chmod 2775 {} +
find /srv/media/<wrong-dir> -type f -exec chmod 0664 {} +
```

Without these perms set correctly, Lidarr / slskd / ytdl-sub will
fail with permission-denied on first write — and the failure mode is
silent enough to debug for hours.

## One-time post-deploy setup

After the first `tools/apply.sh` brings up LXCs 105 and 106:

1. **Navidrome → YouTube library.** Settings → Libraries → +. Path:
   `/var/lib/navidrome/media/youtube`. Name: `YouTube`. (Multi-library
   is web-UI-only in Navidrome — see comment in
   `services/navidrome/target/navidrome.toml.tmpl`.)
2. **Lidarr → quality profiles + indexers.** UI at
   `https://lidarr.${HOMELAB_DOMAIN}`. Authelia gates access. Set up a
   FLAC-preferred quality profile and add the soularr-managed slskd
   indexer (URL `http://127.0.0.1:5030`, API key from
   `/etc/lidarr-stack/secrets.env` on the LXC).
3. **slskd → Soulseek folder shares.** UI at
   `https://slskd.${HOMELAB_DOMAIN}`. Verify the share roots match
   `services/lidarr/target/slskd.yml.tmpl → shares.directories`.
4. **ytdl-sub → subscriptions.** Edit
   `services/ytdl-sub/target/subscriptions.yaml` with the channels /
   playlists / artists you want. Run `tools/apply.sh` to sync. First
   sync runs at next 04:00 (or manually:
   `ssh root@<ytdl-sub-ip> systemctl start ytdl-sub.service`).

## Where secrets live

| Secret | Source | Consumer |
|---|---|---|
| `SOULSEEK_USERNAME` / `SOULSEEK_PASSWORD` | `iac/secrets.sops.yaml` (user-set) | slskd via envsubst into `slskd.yml` |
| `LIDARR_API_KEY` | `random_secrets` directive (LXC 105 local) | Lidarr config.xml + soularr ExecStartPre |
| `SLSKD_API_KEY` / `SLSKD_JWT_KEY` | `random_secrets` directive (LXC 105 local) | slskd EnvironmentFile + soularr ExecStartPre |

The two soularr-consumed API keys never leave LXC 105 — they're
generated by the bootstrap engine inside the LXC's
`/etc/lidarr-stack/secrets.env` and read at runtime via systemd
`EnvironmentFile=`.

## Backups

Reproducible (re-acquirable) data — media files — are NOT backed up.
What's backed up via `services/lidarr/backups.yaml` (SQLite engine,
same pattern as Navidrome / Authelia):

- `lidarr.db` — artists, albums, wanted list, quality profiles
- `logs.db`  — operational history
- `catalog.db` — slskd transfer history

Soularr is stateless (a poller) — no backup target.
ytdl-sub state derives from `subscriptions.yaml` (in git) + already-
downloaded files (on disk) — no backup target.
