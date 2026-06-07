# Backups

Single source of truth for everything backup-related in the homelab:
storage layout, current strategy, restore procedures, gaps, and the
planned PBS migration. If it's about losing or recovering data, it's
here.

## TL;DR

Everything is captured by **one daily `vzdump` job** on the PVE host
(03:00 → USB SSD at `/mnt/pve/backup`). Two assets are NOT in that job
by design: **media files** (excluded via `backup: false` on the LXC
mount point) and **encrypted secrets** (live in git + R2).

Restore = `pct restore <id> backup:backup/vzdump-lxc-<id>-...` from any
recent snapshot. Loss tolerance is **≤24h** for service state, **0** for
media (intact at source) and secrets (in git).

## What backs up what

```
┌─────────────────────────────────────────────────────────────────┐
│ Asset                          │ Mechanism            │ RPO     │
├────────────────────────────────┼──────────────────────┼─────────┤
│ Service state (configs, DBs)   │ vzdump daily 03:00   │ ≤24h    │
│ Navidrome DB                   │ vzdump + sqlite3 dump│ ≤24h    │
│ Music library (FLACs)          │ NOT backed up*       │ N/A     │
│ Secrets (sops-encrypted)       │ git + R2 + age key   │ commit  │
│ Tofu state                     │ R2 (CF), PBKDF2-AES  │ apply   │
│ Age private key                │ YOUR responsibility† │ —       │
└─────────────────────────────────────────────────────────────────┘
```

\* Music is a reproducible asset — originals live elsewhere (rip source,
CD, download). If the LXC dies, restore the LXC (state + DB) from
vzdump, then re-sync music with `rsync` from your local copy. The
Navidrome DB preserves ratings/playlists/play counts.

† The age private key (`~/.config/sops/age/keys.txt`) is what unlocks
`iac/secrets.sops.yaml`. Lose it and the encrypted file in git is
unreadable. Keep a copy in a password manager / printed in a safe.

## Storage layout

Backups land on the `backup` storage pool. Current PVE host (`pve03`,
Beelink) layout:

| Storage | Backing | Path | Content | Capacity |
|---|---|---|---|---|
| `local` | Internal SSD M.2 | `/var/lib/vz` | import, iso, vztmpl | — |
| `local-lvm` | Internal SSD M.2 (LVM-thin) | `/dev/pve/data` | rootdir, images | 365 GB |
| `backup` | USB SSD Samsung 860 EVO 500GB | `/mnt/pve/backup` | backup, iso, vztmpl, images, rootdir, snippets | 480 GB |

Adequate for the current 5 LXCs (~8 GB used). Will get tight when media
grows or more LXCs are added.

The Seagate ST2000LM007 HDD (SMR) was originally mounted as the backup
target, but UAS + SMR caused journal aborts under sustained writes. It is
still plugged in physically but removed from the storage config and
fstab. Retired entirely once PBS lands on dedicated hardware.

## Initial PVE backup-target setup (one-time, per host)

On a fresh PVE install, `vzdump` has no storage to write to. Steps:

1. Plug a USB SSD (or use a permanent disk).
2. `mkfs.ext4 -L backup /dev/sdX1` (partition first if needed).
3. Add to `/etc/fstab` using UUID with
   `nofail,x-systemd.device-timeout=10s,noatime`.
4. `pvesm add dir backup --path /mnt/pve/backup --content backup,iso,vztmpl --is_mountpoint 1`
5. Confirm the `daily-all` vzdump job exists in `/etc/pve/jobs.cfg`
   (definition below). If not, create it via UI: Datacenter → Backup →
   Add.

This is currently **imperative state on the PVE host**, not in this
repo. See the "Known gaps" section.

## The vzdump job (current)

Defined in `/etc/pve/jobs.cfg` on the PVE host:

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

## Coverage matrix

Quick reference of what every LXC contributes to the backup story:

| LXC                   | Inner backup spec                                  | Engine     | What it captures                       |
|---|---|---|---|
| coolify (200)         | `services/coolify/backups.yaml`                    | postgres   | Coolify source DB (projects, deploys)  |
| gateway (103)         | `services/gateway/backups.yaml`                    | sqlite     | Authelia DB (TOTP, sessions, audit)    |
| navidrome (104)       | `services/navidrome/backups.yaml`                  | sqlite     | Navidrome DB (users, ratings, scrobbles) |
| adguard (102)         | —                                                  | —          | BoltDB + flock blocks online dump; vzdump only (see below) |
| coolify-runner-01 (210) | —                                                | —          | Pure Docker host; per-app future       |
| ops (101)             | —                                                  | —          | Rootfs covered by vzdump               |

Backups are **declarative**: `services/<svc>/backups.yaml` is the spec,
`tools/lib/assemble-crons` translates it into cron entries that invoke
`tools/lib/backups/run.sh`. No per-service shell script — adding a new
backup is editing one YAML file. All entries run at 02:50 UTC (10 min
before vzdump's 03:00) and write to the target LXC's rootfs so the host
snapshot captures them.

## Per-service exceptions

### Navidrome — sqlite3 .backup of the SQLite DB + vzdump

Navidrome's SQLite DB at `/var/lib/navidrome/navidrome.db` holds users,
ratings, playlists, scrobbles, play counts — none of which is
declarative. Same pattern as Authelia (the engine even uses the same
`tools/lib/backups/sqlite.sh` helper):

Spec: `services/navidrome/backups.yaml` (1 entry, `engine: sqlite`).
The cron entry is generated by `tools/lib/assemble-crons` and invokes
`tools/lib/backups/run.sh --engine sqlite ...`. No per-service script.

Output: `root@navidrome:/var/lib/navidrome/backups/navidrome-<UTC-ts>.sqlite3`
Method: `sqlite3 SRC ".backup DEST"` then `PRAGMA integrity_check`
Retention: `keep_last: 14`

Navidrome's own `[Backup]` toml block is **intentionally not enabled** —
every service follows the same declarative YAML pattern.

**Restore the DB only** (no LXC recreate):
```bash
# On the Navidrome LXC
systemctl stop navidrome
LATEST=$(ls -t /var/lib/navidrome/backups/navidrome-*.sqlite3 | head -1)
cp "$LATEST" /var/lib/navidrome/navidrome.db
chown navidrome:navidrome /var/lib/navidrome/navidrome.db
systemctl start navidrome
```

### Coolify — pg_dump of the source DB + vzdump

Coolify's own state (projects, server records, environment variables,
deploy history, OIDC clients, …) lives in a Postgres container named
`coolify-db` inside the LXC 200. A filesystem-level vzdump snapshot
captures the data files but doesn't produce a logically-consistent
dump — Postgres recovery on restore is fine in theory, but a clean
`pg_dump` is strictly better for selective restores and migrations.

We dump it ourselves via cron:

Spec: `services/coolify/backups.yaml` (1 entry, `engine: postgres`).
The cron entry is generated by `tools/lib/assemble-crons` and invokes
`tools/lib/backups/run.sh --engine postgres ...`.

Output: `root@coolify:/data/coolify/backups/source/coolify-source-<UTC-ts>.dmp`
Format: `pg_dump --format=custom --no-acl --no-owner`
Retention: `keep_last: 14` (matches vzdump window)

The dumps live on the Coolify LXC's rootfs, so vzdump captures them at
03:00. Net effect: **two independent snapshots of the source DB per day**
at different layers (logical dump + filesystem snapshot).

We deliberately do NOT use Coolify's own "Backups" UI/scheduler. See the
"Inner backup pattern" section below for why.

**Restore the source DB only** (no LXC recreate):
```bash
# On the Coolify host
LATEST=$(ls -t /data/coolify/backups/source/coolify-source-*.dmp | head -1)
docker exec -i coolify-db pg_restore --clean --if-exists -U coolify -d coolify < "$LATEST"
docker restart coolify
```

**Deployed apps' data** (Docker volumes of apps you deploy via Coolify):
covered by the LXC's vzdump only. If a specific deployed app needs more
aggressive or off-host backups, that's app-level work (e.g. a sidecar
that ships dumps to R2).

### Authelia — sqlite3 .backup of the SQLite DB + vzdump

Authelia stores TOTP enrollments, session tokens, identity-verification
cookies, and audit log in `/var/lib/authelia/db.sqlite3` (WAL mode).
A filesystem snapshot of a live SQLite-WAL DB can land in a state that
needs WAL recovery on next open — usually fine, occasionally not. The
SQLite Backup API (`.backup` dot-command) produces a single consistent
file safe to restore anywhere. TOTP secrets in particular cannot afford
corruption — re-enrollment is a manual user action.

Spec: `services/gateway/backups.yaml` (1 entry, `engine: sqlite`).
The cron entry is generated by `tools/lib/assemble-crons` and invokes
`tools/lib/backups/run.sh --engine sqlite ...`.

Output: `root@gateway:/var/lib/authelia/backups/authelia-<UTC-ts>.sqlite3`
Method: `sqlite3 SRC ".backup DEST"` then `PRAGMA integrity_check`
Retention: `keep_last: 14`

The `sqlite3` CLI is installed in `services/gateway/scripts/bootstrap.sh`.

**Restore the Authelia DB only**:
```bash
# On the gateway LXC
systemctl stop authelia
LATEST=$(ls -t /var/lib/authelia/backups/authelia-*.sqlite3 | head -1)
cp "$LATEST" /var/lib/authelia/db.sqlite3
chown authelia:authelia /var/lib/authelia/db.sqlite3
systemctl start authelia
```

### AdGuard — vzdump only (no inner backup possible)

AdGuard's state is split:
- `AdGuardHome.yaml` — DNS settings, rewrites, filter URLs, users.
  Already declarative: `services/adguard/AdGuardHome.yaml.tmpl` is
  rendered by the sync engine (`services/adguard/sync.yaml`) on every
  apply. vzdump captures the rendered file; git has the source.
- `data/stats.db` — months of DNS query history, blocked counts, top
  domains. **BoltDB** (not SQLite).
- `data/sessions.db` — login sessions, ephemeral.
- `data/filters/` — re-downloaded from upstream URLs.

**No inner backup script exists** for AdGuard, and (after investigation)
none can be added with our online-backup-no-downtime constraint. Why:

- AdGuard opens stats.db with `bbolt.Open(filename, perm, nil)` — `nil`
  options means writer mode, which acquires a POSIX **LOCK_EX** on the
  file descriptor and holds it for the entire process lifetime.
  (`references/AdGuardHome/internal/stats/stats.go`)
- `bbolt compact` (the canonical online backup tool for BoltDB) opens
  the source as `bolt.Options{ReadOnly: true}`, which acquires
  **LOCK_SH**. (`references/bbolt/cmd/bbolt/command/command_compact.go`)
- POSIX LOCK_SH is incompatible with LOCK_EX → `bbolt compact` blocks
  indefinitely (default timeout=0) or fails. Confirmed: `lsof` shows
  AdGuard holding the file with FD mode `uW` (write-locked).
  (`references/bbolt/bolt_unix.go::flock`)

There is no way to take a clean inner snapshot without stopping
AdGuard, which would interrupt LAN DNS resolution. Two reasons that's
acceptable:

1. **BoltDB is transaction-safe at the filesystem level.** Writes go
   through copy-on-write pages with an atomic 16-byte meta-page swap.
   A vzdump snapshot captures the file at one instant; on next open
   BoltDB sees a consistent meta page and any in-flight pages from an
   incomplete transaction are simply unreferenced. No corruption.
2. **The stats are nice-to-have, not load-bearing.** Restored history
   may be ≤24h stale (vzdump cadence). The AdGuard config — the
   load-bearing part — is reconstructed from git on disaster restore
   regardless.

AdGuard also exposes `GET /stats` returning aggregated JSON. That is
useful for long-term archival/auditing into an external time-series
store, but it's not a restorable DB dump and is orthogonal to the
backup story.

**Restore is just `pct restore` of the whole LXC** — the `data/stats.db`
file inside is recovered as-is, BoltDB handles the rest on next open.

### Caddy / cloudflared / coolify-runner-01 — no state to inner-back

- **Caddy** (on gateway LXC) reads `/etc/caddy/Caddyfile`, rendered by
  the sync engine from `services/gateway/caddy/sync.yaml`. No DB.
- **cloudflared** connectors on Coolify + runner LXCs are stateless;
  the tunnel token comes from sops + tofu. No DB.
- **coolify-runner-01** is a pure Docker host with no own state. Apps
  deployed via Coolify will have their own data (volumes, DBs); when
  apps are deployed, each one should get its own backup script under
  its app repo — same pattern as services here.

### ops LXC (101) — covered by vzdump

The ops LXC holds the git checkout, the SSH key it uses to reach every
other LXC, and the age private key that decrypts `secrets.sops.yaml`.
All three live on rootfs and are captured by vzdump. The git checkout
is trivially recreatable; the SSH key is also installed on PVE; the
age key is the operator's responsibility to also keep off-host (a copy
in your password manager — see "Restore secrets").

No inner backup script for ops itself.

## Inner backup pattern (`tools/lib/backups/`)

"Inner" backups = per-app database dumps (pg_dump, sqlite3 .backup, …)
that complement the host-level vzdump snapshot. Triggered by cron from
ops, they write their output **on the target LXC's rootfs** so vzdump
captures the dump alongside the rest of the LXC.

### Layout

```
tools/lib/backups/
├── run.sh                  driver — dispatched by cron; --engine X ...
├── postgres.sh             pg_dump_in_container helper
├── sqlite.sh               sqlite_backup_remote helper (+ integrity_check)
└── retention.sh            rotate_keep_last helper

services/<svc>/
└── backups.yaml            declarative spec (list of backup entries)

tools/lib/assemble-crons    Go program that reads each backups.yaml +
                            cron.yaml and emits /etc/cron.d/iac
```

The flow: assemble-crons reads `services/*/backups.yaml`, validates each
spec against its engine schema, and emits a cron entry per backup that
calls `tools/lib/backups/run.sh` with `--engine X --name Y …` flags.
At cron time, `run.sh` parses its own flags, dispatches to the right
engine helper, and rotates the dest dir.

### Backup spec schema (`services/<svc>/backups.yaml`)

```yaml
- name: <unique-identifier>     # cron entry name; dump filename prefix; log filename
  engine: postgres|sqlite       # dispatcher key
  host: <service-name>          # resolved via ip_of from network/ips.yaml
  dest_dir: /absolute/path      # on the target host (vzdump captures it)
  retention:                    # vocabulary aligns with PVE vzdump prune-backups
    keep_last: <int>            # mandatory: keep the N most recent dumps
    # keep_daily: <int>         # future: 1 per day for N days
    # keep_weekly: <int>        # future: 1 per week for N weeks
  schedule: "50 2 * * *"        # cron expression, UTC

  # postgres-specific:
  container: <docker-name>
  user: <postgres-user>
  database: <db-name>

  # sqlite-specific:
  src: /absolute/path/to/file.db
```

Dump file naming convention:
- `<dest_dir>/<name>-<UTC-ts>.dmp` (postgres, pg_dump custom format)
- `<dest_dir>/<name>-<UTC-ts>.sqlite3` (sqlite)

### Why not the app's own scheduler?

Same reasoning as the rest of this repo's IaC-vs-UI stance:

- **Declarative**: schedule + retention + format live in git, visible
  at review time, not buried in app DB rows.
- **Uniform restore mental model** across services, regardless of what
  each app's native UI calls things.
- **Survives upgrades**: app schema changes can break their native
  backup config. A `docker exec ... pg_dump` is stable across versions.
- **Observable**: cron output goes to a known log file; failures show
  up in the same channel as drift checks.

Trade-off: no "Backups" tab in the app UI. Acceptable — this homelab
is IaC-driven. No exceptions: every backed-up service follows this
pattern, including Navidrome (its native `[Backup]` block was removed
in favor of the script).

### Adding inner backups for a new service

1. If the engine helper doesn't exist yet, add `tools/lib/backups/<engine>.sh`
   (function signature similar to `postgres.sh::pg_dump_in_container` or
   `sqlite.sh::sqlite_backup_remote`) and wire it into
   `tools/lib/backups/run.sh`'s dispatcher + Go assembler validation.
2. Add an entry to `services/<svc>/backups.yaml` with the engine, host,
   dest_dir, retention.keep_last, schedule + engine-specific fields.
3. Update this doc's coverage matrix + per-service section.
4. `tools/apply.sh` regenerates `/etc/cron.d/iac` automatically.

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

**If the age key is lost AND no second recipient exists** (worst case):
create a new age key, regenerate the sops file from scratch via
`tools/seed-secrets.sh` + `sops` (template flow), then re-encrypt all
tofu state with `tofu init -migrate-state` after editing the
`encryption{}` block to map old → new passphrase. Every secret in
`secrets.template.yaml` must be re-seeded by hand.

### Restore tofu state

State lives in Cloudflare R2 (`s3://homelab-iac-state/...`), encrypted
at rest by tofu's `encryption{}` block with `TOFU_STATE_PASSPHRASE`.

```bash
# Recover a corrupted local state by re-pulling from R2
aws s3 cp s3://homelab-iac-state/infra/terraform.tfstate /tmp/
# Or list versions if R2 versioning is on
aws s3api list-object-versions --bucket homelab-iac-state --prefix infra/
```

Today the only safety net for R2 is OpenTofu's `encryption{}` block plus
R2's 24h soft-delete window. A daily `aws s3 cp` of the state to a
second location is a candidate for `iac/cron.yaml` (TODO, not
implemented).

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
   - Fix: PBS migration (see next section). PBS chunks at 4 MiB with
     content-defined boundaries; daily incremental of an unchanged LXC
     is essentially free.

4. **The `daily-all` job is configured imperatively on the PVE host**
   (`/etc/pve/jobs.cfg`), not in this repo. Re-creating the PVE host
   from scratch requires re-running the "Initial PVE backup-target
   setup" section by hand.
   - Fix: tofu the vzdump job. Low priority — it's a 5-line one-time
     setup, and the bpg/proxmox provider doesn't model jobs.cfg yet
     last I checked.

## Future: PBS 4.2 migration (planned)

When the 3-node cluster lands (see `3-node-plan.md` for the cluster
plan itself), the backup target migrates from "vzdump → USB SSD" to
**PBS 4.2** running as an LXC on `pve01`. This rewrites most of the
gaps above. Architectural decision recap:

**Why PBS over staying on vzdump-USB:**
- Dedupe ~10-20× on LXCs with similar OS bases
- Content-defined chunking (4 MiB): incremental of an unchanged LXC ≈ 0 bytes
- Native verify jobs (catches corruption proactively)
- GC + retention as first-class operations
- Sync jobs to a second datastore (off-site or offline copy)

**Why PBS in an LXC, not a 4th physical host:**
- Officially recommended as a VM, but community runs it in LXC for years
- Trade-off: PBS on a cluster node = SPOF if that node dies. Mitigated
  by sync to a second datastore (the USB SSD as offline copy)
- A 4th dedicated device would be more correct, but the Beelink + USB
  still survives as "off-site improvised"

**Plan when PBS lands:**
- LXC `pbs` on `pve01`, Debian 13, 2c/4G/100G
- Primary datastore on a dedicated ZFS dataset: `zfs create tank/pbs-store`
- Add as storage `pbs-main` in Datacenter
- Migrate `daily-all` from vzdump-to-HDD to PBS
- USB SSD repurposed as secondary datastore with sync job

**PBS 4.2 features (April 2026) that change the design:**
- **Native S3 object storage backend** — datastore can be an S3-compat
  bucket (R2, Wasabi, B2). Reduces dependency on local disk; if the
  PBS-host node dies, backups survive in S3.
- **Server-side encryption in push sync jobs** — snapshots encrypted
  before leaving for the secondary datastore. Useful for untrusted
  off-site targets.
- **Improved multi-datastore sync** — PBS-in-LXC + USB SSD as secondary
  becomes a native config, no rsync wrapper needed.

**Revised plan**: PBS in LXC on `pve01`, primary datastore on R2 (or
MinIO in a sibling LXC), secondary copy to USB SSD with server-side
encryption. Closes gaps 1, 2, 3 from above in one move.

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
