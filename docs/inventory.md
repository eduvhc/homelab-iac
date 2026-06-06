# Inventory

Single source of truth for what runs where. Keep in sync with PVE tags
(`pct set <id> --tags "a;b"`) and hostnames (`pct set <id> --hostname X`).

## LXCs

| ID  | Hostname            | IP                | Tags                 | Purpose |
|-----|---------------------|-------------------|----------------------|---------|
| 101 | ops                 | 192.168.50.101    | infra, iac           | OpenTofu, sops+age, git, sync ops |
| 102 | adguard             | 192.168.50.30     | infra, dns           | AdGuard Home (DNS + split-DNS rewrites for *.<homelab_domain>) |
| 103 | gateway             | 192.168.50.40     | infra, sso           | Caddy + Authelia (SSO for homelab admin UIs) |
| 200 | coolify             | 192.168.50.200    | coolify, control-plane | Coolify UI + cloudflared (CF tunnel terminator) |
| 210 | coolify-runner-01   | 192.168.50.210    | coolify, runtime     | Docker engine + Traefik for apps deployed via Coolify |

## Tag schema

Tags are layered by intent:

- **Category** (always one): `infra` (supporting services), `coolify`
  (anything Coolify-related). Future: `data` (databases), `obs`
  (monitoring), etc.
- **Sub-function** (always one): describes what this specific LXC does
  inside its category.
  - infra: `iac`, `dns`, `sso`, future `vpn`, `backup`, ...
  - coolify: `control-plane`, `runtime`

**PVE display order.** `/etc/pve/datacenter.cfg` has `tag-style:
ordering=config`, so the UI shows tags in the order they are written, not
alphabetically. Always write tags as broader-category-first then
specific-subfunction (e.g. `infra;dns`, `coolify;runtime`).

When adding a new LXC, pick one category and one sub-function tag. If
neither fits, add a new sub-function tag rather than overloading existing
ones.

## Hostname conventions

- Single-instance services use the short purpose name (`ops`, `adguard`,
  `gateway`, `coolify`).
- Pooled/scalable services use `<purpose>-<NN>` where NN is a zero-padded
  sequence (`coolify-runner-01`, `coolify-runner-02`, ...). Avoids
  ambiguous names like `deploy` or `server`.

## Cross-host scaling (future)

When new PVE nodes arrive (see `3-node-plan.md`):

- The Beelink (`pve03`) keeps the infra LXCs (101, 102, 103). Low
  resource, sticky to a node.
- `coolify` control plane (200) goes to `pve01`.
- `coolify-runner-NN` instances spread across `pve01` and `pve02` for
  capacity. `pve03` can host a runner as a tertiary if needed.

## PVE storages

| Name | Backing | Path | Content | Notes |
|------|---------|------|---------|-------|
| local | Internal SSD M.2 | /var/lib/vz | import, iso, vztmpl | Default |
| local-lvm | Internal SSD M.2 (LVM-thin) | /dev/pve/data | rootdir, images | Primary disk store for LXCs/VMs |
| backup | USB SSD (Samsung 860 EVO 500GB) | /mnt/pve/backup | backup, iso, vztmpl, images, rootdir, snippets | vzdump target |

The Seagate ST2000LM007 HDD (SMR) was originally mounted as the backup
target, but UAS + SMR caused journal aborts under sustained writes. It is
still plugged in physically but removed from the storage config and
fstab. When real hardware arrives, PBS on a dedicated machine becomes the
backup target and the HDD is retired entirely.


## LXCs as code (bpg/proxmox, data-driven from YAML)

The 4 service LXCs (102, 103, 200, 210) are defined **declaratively in
YAML**, not in `.tf`. The infra stack at `iac/stacks/infra/` discovers
both files at apply time via `fileset()` + `yamldecode()`.

- **`network/ips.yaml`** holds central LAN topology and the service-name
  → IP map. IPs do NOT change when an LXC migrates between PVE nodes.
- **`services/<svc>/lxc.yaml`** is the per-LXC spec (vm_id, hostname,
  cores, memory, disk, `node`, `features`, `tags`). Moving a service to
  another PVE node is a one-line change to the `node:` field.

LXC 101 (ops) is intentionally **not** declared. It's where tofu runs.
Bootstrap manually per `docs/setup-from-scratch.md` Phase 0.

### Caveats of using bpg/proxmox

These are the rough edges to know.

- `lifecycle.ignore_changes` skips drift on three fields that are
  one-shot at LXC creation:
  - `operating_system.template_file_id`. Coolify install is destructive
    on template change. Re-templating would nuke the LXC. Don't.
  - `initialization.user_account`. SSH key injection happens at creation.
    Rotating keys is done via direct `authorized_keys` edit, not via tofu.
  - `network_interface.mac_address`. Randomly assigned at creation. Tofu
    wants to manage it, but rotating would force replace.
- The provider needs the PVE API to be reachable for **every** plan or
  apply, including for unrelated changes (CF DNS edits, etc.). If PVE is
  down, tofu is stuck. Accepted trade-off.

### Adding a new LXC

Two file edits, then `tofu apply`. Example for a Grafana LXC on `pve02`:

```yaml
# network/ips.yaml: add a row
services:
  # ... existing ...
  grafana:  192.168.50.250

# services/grafana/lxc.yaml: create this file
vm_id: 250
hostname: grafana
cores: 1
memory_mb: 1024
swap_mb: 256
disk_gb: 10
node: pve02
tags: [obs, metrics]
features: {nesting: false, keyctl: false}
```

```bash
cd iac/stacks/infra && tofu apply
```

Bootstrap stays manual per service. Create `services/grafana/bootstrap.sh`
and have `tools/apply.sh` (or a one-off ssh) run it after the LXC is up.

### Adding a tunnel route for the new LXC

If the new LXC should be reachable from the public internet via the CF
tunnel, create `services/grafana/tunnel-routes.yaml`:

```yaml
- hostname: grafana
  upstream: {host: grafana, port: 3000}
```

The infra stack picks it up automatically. It adds the DNS CNAME and the
tunnel ingress rule on next `tofu apply`. The wildcard catch-all
(`hostname: "*"`) is already owned by
`services/coolify-runner-01/tunnel-routes.yaml`.
