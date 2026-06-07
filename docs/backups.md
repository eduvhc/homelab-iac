# Backups

How data in the homelab is protected today, and what the realistic failure
recovery paths look like. Read this before deleting anything important.

> Companion docs: `inventory.md` (storage table), `setup-from-scratch.md`
> (PVE backup target init), `3-node-plan.md` (future PBS migration).

## TL;DR

Everything is backed up by **one daily `vzdump` job** on the PVE host,
running at 03:00 → USB SSD at `/mnt/pve/backup`. Two things are NOT in
that job by design: **media files** (excluded via `backup: false` on the
mount point) and **encrypted secrets** (live in this git repo + R2).

Restore = `pct restore <id> backup:backup/vzdump-lxc-<id>-...` from any
recent snapshot. Loss tolerance is **≤24h** for service state, **0** for
media (intact at source) and secrets (in git).

## What backs up what

```
┌─────────────────────────────────────────────────────────────────┐
│ Asset                          │ Mechanism            │ RPO     │
├────────────────────────────────┼──────────────────────┼─────────┤
│ Service state (configs, DBs)   │ vzdump daily 03:00   │ ≤24h    │
│ Navidrome DB                   │ vzdump + native dump │ ≤24h    │
│ Music library (FLACs)          │ NOT backed up*       │ N/A     │
│ Secrets (sops-encrypted)       │ git + R2 + age key   │ commit  │
│ Tofu state                     │ R2 (CF), PBKDF2-AES  │ apply   │
│ Age private key                │ YOUR responsibility† │ —       │
└─────────────────────────────────────────────────────────────────┘
```

\* Music is treated as a reproducible asset — originals live elsewhere
(your rip source, the CD, the download). If the LXC dies, restore the
LXC (state + DB) from vzdump, then re-sync music with `rsync` from your
local copy. The Navidrome DB preserves ratings/playlists/play counts.

† The age private key (`~/.config/sops/age/keys.txt`) is what unlocks
`iac/secrets.sops.yaml`. Lose it and the encrypted file in git is
unreadable. Keep a copy in a password manager / printed in a safe.

## The vzdump job (current)

Defined in `/etc/pve/jobs.cfg` on the PVE host (NOT in this repo —
managed once, see `setup-from-scratch.md`):

```ini
vzdump: daily-all
    all 1                                          # every LXC + VM
    compress zstd
    enabled 1
    mode snapshot                                  # near-zero downtime
    notes-template "{{guestname}}"
    prune-backups keep-last=3,keep-daily=7,keep-weekly=2
    schedule 03:00
    storage backup
```

**Retention math** for any one LXC, on any given day:
- `keep-last=3` — the 3 most recent dumps regardless of age
- `keep-daily=7` — the latest dump per day for the last 7 days
- `keep-weekly=2` — the latest dump per week for the last 2 weeks

Effective window: ~14 days of recoverable history per LXC. Retention is
**per guest**, not per job — adding more LXCs grows the storage demand
linearly, not the retention depth.

**Storage target** (`backup` in `pvesm status`):

| Backing | Path | Capacity | Used (2026-06) |
|---|---|---|---|
| USB SSD Samsung 860 EVO 500GB | `/mnt/pve/backup` | 480 GB | ~8 GB (1.7%) |

Adequate for the current 5 LXCs. Will get tight when media grows.

## State vs media separation (the load-bearing pattern)

`vzdump` does not deduplicate. A 100 GB music library would produce
~100 GB per snapshot — the USB SSD fills in 5 days. To avoid this, media
services use **separate LVM volumes** that `vzdump` skips.

Declared centrally in `services/<svc>/lxc.yaml`:

```yaml
disk_gb: 8                                   # rootfs → vzdump captures
mount_points:
  - path: /var/lib/navidrome/music
    size_gb: 50                              # mp0 → separate volume
    backup: false                            # excluded from vzdump
```

Behind the scenes, `iac/stacks/infra/lxc.tf` translates `mount_points:`
into a `dynamic "mount_point"` block on the LXC resource. `backup: false`
sets the PVE container flag that `vzdump` reads.

**Verify per-LXC** (on PVE host):
```bash
pct config 104 | grep ^mp                    # mp0: ..., backup=0
```

**Verify per-job** (after a backup runs):
```bash
ls -lh /mnt/pve/backup/dump/vzdump-lxc-104-*.tar.zst
# Should be ~rootfs size (≤8GB compressed), NOT rootfs + music
```

## Per-service exceptions

### Navidrome — native DB backup in addition to vzdump

Navidrome has an in-process backup that dumps just the SQLite DB to
`/var/lib/navidrome/backups/` on a schedule. Configured in
`services/navidrome/navidrome.toml.tmpl`:

```toml
[Backup]
Path     = "/var/lib/navidrome/backups"
Schedule = "0 3 * * *"
Count    = 14
```

That dir lives on rootfs, so `vzdump` captures it. Net effect: **two
independent DB snapshots per day** (the native one at 03:00, the vzdump
one shortly after), at different layers — defense in depth.

Why bother with both? The native dump is a clean SQLite file you can
copy out and `sqlite3` into anywhere. The vzdump captures the live DB
mid-write (snapshot mode is consistent at the filesystem level, but a
SQLite WAL may need recovery on restore). The native dump is the
preferred restore source; vzdump is the fallback if the LXC is gone.

**Restore the DB only** (no LXC recreate needed):
```bash
# On the LXC
systemctl stop navidrome
sqlite3 /var/lib/navidrome/navidrome.db ".restore /var/lib/navidrome/backups/navidrome_backup_<ts>.db"
systemctl start navidrome
```

### Coolify — app data lives inside the LXC

Coolify apps store data in Docker volumes inside the LXC (200). The
LXC's vzdump covers them. There's no per-app backup config in this repo
— if a specific deployed app needs more aggressive backups (off-host),
that's app-level work (e.g. a sidecar that ships dumps to R2).

### AdGuard / gateway / runner — pure state, all in rootfs

No special handling. The vzdump captures everything.

## Restore procedures

### Restore an entire LXC

From the PVE host:
```bash
# List available backups for LXC 104
ls /mnt/pve/backup/dump/vzdump-lxc-104-*.tar.zst

# Restore. Use --force to overwrite the existing LXC (it must be stopped first).
pct stop 104
pct restore 104 backup:backup/vzdump-lxc-104-2026_06_07-03_00_00.tar.zst --force
pct start 104
```

For Navidrome specifically, the music dir is empty after restore (mp0
recreated blank) — re-sync from your local copy. The DB inside rootfs
is restored, so ratings/playlists/users survive.

### Restore a single file

`vzdump` archives are plain `tar.zst`. No PVE involvement required:
```bash
tar --zstd -tf /mnt/pve/backup/dump/vzdump-lxc-104-*.tar.zst | grep navidrome.db
tar --zstd -xf /mnt/pve/backup/dump/vzdump-lxc-104-*.tar.zst -C /tmp ./var/lib/navidrome/navidrome.db
```

### Restore secrets (sops file)

Secrets are in git, encrypted. To read them you need the age private key.

```bash
# Fresh machine: install age + sops
mkdir -p ~/.config/sops/age && cp /path/to/your/backup/keys.txt ~/.config/sops/age/
chmod 600 ~/.config/sops/age/keys.txt
sops -d iac/secrets.sops.yaml | head
```

Lose the age key and the sops file in git is permanently unreadable.
The `.sops.yaml` recipients list supports multiple keys — you can add
a second age key (e.g. a YubiKey-stored one) as off-site recovery.

### Restore tofu state

State lives in Cloudflare R2 (`s3://homelab-iac-state/...`), encrypted
at rest by tofu's `encryption{}` block with `TOFU_STATE_PASSPHRASE`.

```bash
# Recover a corrupted local state by re-pulling from R2
aws s3 cp s3://homelab-iac-state/infra/terraform.tfstate /tmp/
# Or list versions if R2 versioning is on
aws s3api list-object-versions --bucket homelab-iac-state --prefix infra/
```

## Disaster scenarios

| Scenario | Loss | Recovery |
|---|---|---|
| One LXC dies (corruption, fat-finger) | ≤24h of that LXC's state | `pct restore` from vzdump |
| Music dir wiped | Ratings/playlists/play counts intact in DB | `rsync` music back from your local copy |
| PVE host SSD dies | All LXCs gone; vzdump on USB SSD survives | New PVE install → `pct restore` each LXC from the USB SSD |
| USB SSD dies | No restore points; LXCs still running | Replace SSD, recreate `backup` storage, wait for next 03:00 dump |
| PVE host + USB SSD both die (fire, theft) | **Everything except what's in git + R2** | Rebuild PVE, run `tools/apply.sh` (creates LXCs fresh from declarative spec, no service state) |
| Age key lost | Cannot decrypt `secrets.sops.yaml` | Rotate all secrets, re-encrypt with a new age key, push |
| R2 bucket purged | Tofu state gone — must reimport everything | Use `tofu import` per resource against existing PVE/CF state |

The realistic worst case for "I lose the building" scenario is **rebuild
from scratch using the repo + a copy of the age key**. Services come up
clean (no app data, no Navidrome history). This is the deliberate design
trade-off — no off-site backup of LXC state today.

## Known gaps (and what fixes them)

1. **No off-site backup of vzdump archives.** A fire takes everything.
   - Fix: rsync `/mnt/pve/backup/dump/` to R2 nightly. Cheap (~$5/mo per
     50 GB compressed). Trade-off: extra script, R2 egress on restore.

2. **No backup verification.** A corrupt vzdump goes unnoticed until
   you try to restore.
   - Fix: weekly `pct restore` test into a throwaway VMID. Manual today.
     PBS does this automatically with `verify` jobs.

3. **vzdump has no deduplication.** Each daily snapshot is a full
   compressed tarball.
   - Fix: PBS migration (planned, `docs/3-node-plan.md`). PBS chunks at
     4 MiB with content-defined boundaries; daily incremental of an
     unchanged LXC is essentially free. Also adds: client-side encryption,
     S3-compat datastore (R2), verify jobs, GC, sync to a second
     datastore for off-site.

4. **The `daily-all` job is configured imperatively on the PVE host**
   (`/etc/pve/jobs.cfg`), not in this repo. Re-creating the PVE host
   from scratch requires re-running the steps in `setup-from-scratch.md`
   Phase "Backup target" by hand.
   - Fix: tofu the vzdump job. Low priority — it's a 5-line one-time
     setup, and the bpg/proxmox provider doesn't model jobs.cfg yet
     last I checked.

## Mental model for what to back up

When adding a new service, ask:

1. **Is the data reproducible?** Yes (media, build caches, scraped data
   you can re-scrape) → `mount_points:` with `backup: false`.
2. **Is the data small and load-bearing?** (DB, ratings, settings) →
   stays on rootfs, vzdump covers it.
3. **Is the data both large AND unique?** (user uploads, photos you
   shot yourself) → rootfs is wrong AND `backup: false` is wrong. You
   need a dedicated backup strategy (rsync to off-host, S3 sync,
   restic). Don't have this case yet; design when it arrives.

The current homelab has zero category-3 data. If you start hosting
photos / Nextcloud / Immich, that changes.
