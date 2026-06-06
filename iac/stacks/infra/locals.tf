# Inventory: data-driven from the repo. Each service owns its own spec at
# services/<name>/lxc.yaml; the LAN topology (IP allocations + gateway) is
# centralized in network/ips.yaml. Adding a new service = 1 entry in ips.yaml
# + 1 new services/<svc>/lxc.yaml; nothing in this file changes.

locals {
  # ── Network topology (central) ───────────────────────────────────────────────
  _network = yamldecode(file("${path.module}/../../../network/ips.yaml"))

  lan_cidr    = local._network.lan.cidr
  lan_gateway = local._network.lan.gateway
  ips         = local._network.services # service-name -> IP

  # Convenience derivations.
  coolify_api_url = "http://${local.ips.coolify}:8000"

  # ── Per-LXC specs (decentralized) ────────────────────────────────────────────
  # Discover every services/<name>/lxc.yaml relative to this stack. The folder
  # name becomes the service key and MUST match a key in network/ips.yaml.
  _lxc_files = fileset("${path.module}/../../..", "services/*/lxc.yaml")

  lxcs = {
    for f in local._lxc_files :
    split("/", f)[1] => merge(
      yamldecode(file("${path.module}/../../../${f}")),
      { ip = "${local.ips[split("/", f)[1]]}/24" }
    )
  }

  # PVE node assignments derived from each LXC's `node:` field. Useful if
  # ever needed; bpg/proxmox reads it directly from per-LXC `node_name`.
}
