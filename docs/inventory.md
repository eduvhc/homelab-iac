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


## LXCs as code (bpg/proxmox)

The 4 service LXCs (102, 103, 200, 210) are defined declaratively in
`iac/lxc.tf`. To resize, retag, repoint, or move to a different PVE node,
edit the `local.lxcs` map and `tofu apply`.

LXC 101 (ops) is intentionally **not** here — it's where tofu runs. Bootstrap
manually per `docs/setup-from-scratch.md` Step 0.

### Caveats of using bpg/proxmox

These are the rough edges to know:

- `lifecycle.ignore_changes` skips drift on three fields that are one-shot
  at LXC creation:
  - `operating_system.template_file_id` — Coolify install is destructive on
    template change; we'd nuke the LXC by re-templating. Don't.
  - `initialization.user_account` — SSH key injection happens at creation;
    rotating keys is done via direct `authorized_keys` edit, not via tofu.
  - `network_interface.mac_address` — randomly assigned at creation; tofu
    wants to manage it, but rotating would force replace.
- The provider needs the PVE API to be reachable for **every** plan/apply,
  including for unrelated changes (CF DNS edits, etc.). If PVE is down,
  tofu is stuck. Accepted trade-off.
- bpg has historical quirks with LXC features (`nesting`, `keyctl`,
  `unprivileged`). If you see "feature ... is not supported" errors after
  a bpg version bump, check `references/coolify` no wait, the bpg repo
  upstream issues for breaking changes.

### Adding a new LXC

```hcl
locals {
  lxcs = {
    # ... existing entries ...
    grafana = {
      vm_id     = 250
      hostname  = "grafana"
      ip        = "192.168.50.250/24"
      cores     = 1
      memory_mb = 1024
      swap_mb   = 256
      disk_gb   = 10
      tags      = ["obs", "metrics"]
      features  = { nesting = false, keyctl = false }
    }
  }
}
```

Then `tofu apply` creates the LXC. Bootstrap remains manual (run the
relevant `configs/<svc>/scripts/bootstrap.sh` from ops).
