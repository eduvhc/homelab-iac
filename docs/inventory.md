# Inventory

Single source of truth for what runs where. Keep in sync with PVE tags
(`pct set <id> --tags "a;b"`) and hostnames (`pct set <id> --hostname X`).

## LXCs

| ID  | Hostname            | IP                | Tags                 | Purpose |
|-----|---------------------|-------------------|----------------------|---------|
| 101 | ops                 | 192.168.50.101    | infra, iac           | OpenTofu, bws, git, sync ops |
| 102 | adguard             | 192.168.50.30     | infra, dns           | AdGuard Home (DNS + split-DNS rewrites for *.iedora.com) |
| 103 | gateway             | 192.168.50.40     | infra, sso           | Caddy + Authelia (SSO for homelab admin UIs) |
| 200 | coolify             | 192.168.50.200    | coolify, control-plane | Coolify UI + cloudflared (CF tunnel terminator) |
| 210 | coolify-runner-01   | 192.168.50.210    | coolify, runtime     | Docker engine + Traefik for apps deployed via Coolify |

## Tag schema

Tags are layered by intent:

- **Category** (always one): `infra` (supporting services), `coolify` (anything Coolify-related), future: `data` (databases), `obs` (monitoring), etc.
- **Sub-function** (always one): describes what this specific LXC does inside its category.
  - infra: `iac`, `dns`, `sso`, future `vpn`, `backup`, ...
  - coolify: `control-plane`, `runtime`



**PVE display order:** `/etc/pve/datacenter.cfg` has `tag-style: ordering=config`, so the UI shows tags in the order they are written (not alphabetically). Always write tags as broader-category-first then specific-subfunction (e.g. `infra;dns`, `coolify;runtime`).

When adding a new LXC, pick one category + one sub-function tag. If neither fits, add a new sub-function tag rather than overloading existing ones.

## Hostname conventions

- Single-instance services: short purpose name (`ops`, `adguard`, `gateway`, `coolify`).
- Pooled/scalable services: `<purpose>-<NN>` where NN is zero-padded sequence (`coolify-runner-01`, `coolify-runner-02`, ...). Avoids ambiguous names like `deploy` or `server`.

## Cross-host scaling (future)

When new PVE nodes arrive (see `3-node-plan.md`):

- The Beelink (`pve03`) keeps the infra LXCs (101, 102, 103) — low resource, sticky to a node.
- `coolify` control plane (200) goes to `pve01`.
- `coolify-runner-NN` instances spread across `pve01` and `pve02` for capacity. `pve03` can host a runner as a tertiary if needed.

## PVE storages

| Name | Backing | Path | Content | Notes |
|------|---------|------|---------|-------|
| local | Internal SSD M.2 | /var/lib/vz | import, iso, vztmpl | Default |
| local-lvm | Internal SSD M.2 (LVM-thin) | /dev/pve/data | rootdir, images | Primary disk store for LXCs/VMs |
| backup | USB SSD (Samsung 860 EVO 500GB) | /mnt/pve/backup | backup, iso, vztmpl, images, rootdir, snippets | vzdump target |

The Seagate ST2000LM007 HDD (SMR) was originally mounted as backup target,
but UAS + SMR caused journal aborts under sustained writes. It is
physically still plugged but removed from storage config and fstab.
When real hardware arrives, PBS on a dedicated machine becomes the
backup target and the HDD is retired entirely.

