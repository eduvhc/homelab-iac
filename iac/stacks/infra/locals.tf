# Centralized IP and naming data. Anything that references an IP, hostname,
# port, or service URL should reach into here, so changing an inventory
# detail (e.g., moving a service to a different IP) is a one-line edit.
#
# Mirrors docs/inventory.md. Keep both in sync when adding/renumbering.

locals {
  pve_node = "pve"

  # Network constants — used both inside tofu and by shell scripts (via
  # tofu output -> tools/lib/lxc-ips.sh). Keep this block in sync with
  # docs/inventory.md.
  lan_cidr    = "192.168.50.0/24"
  lan_gateway = "192.168.50.1"

  # IPs without prefix; service URLs and LXC `ip` strings add it.
  ips = {
    adguard           = "192.168.50.30"
    gateway           = "192.168.50.40"
    coolify           = "192.168.50.200"
    coolify_runner_01 = "192.168.50.210"
  }

  # Service URLs derived from the above.
  coolify_api_url = "http://${local.ips.coolify}:8000"

  # Per-LXC resource specs. Consumed by proxmox_virtual_environment_container's
  # for_each in lxc.tf.
  lxcs = {
    adguard = {
      vm_id     = 102
      hostname  = "adguard"
      ip        = "${local.ips.adguard}/24"
      cores     = 1
      memory_mb = 512
      swap_mb   = 256
      disk_gb   = 2
      tags      = ["infra", "dns"]
      features  = { nesting = false, keyctl = false }
    }
    gateway = {
      vm_id     = 103
      hostname  = "gateway"
      ip        = "${local.ips.gateway}/24"
      cores     = 1
      memory_mb = 512
      swap_mb   = 256
      disk_gb   = 4
      tags      = ["infra", "sso"]
      features  = { nesting = false, keyctl = false }
    }
    coolify = {
      vm_id     = 200
      hostname  = "coolify"
      ip        = "${local.ips.coolify}/24"
      cores     = 4
      memory_mb = 6144
      swap_mb   = 1024
      disk_gb   = 60
      tags      = ["coolify", "control-plane"]
      features  = { nesting = true, keyctl = true }
    }
    coolify_runner_01 = {
      vm_id     = 210
      hostname  = "coolify-runner-01"
      ip        = "${local.ips.coolify_runner_01}/24"
      cores     = 2
      memory_mb = 4096
      swap_mb   = 1024
      disk_gb   = 30
      tags      = ["coolify", "runtime"]
      features  = { nesting = true, keyctl = true }
    }
  }
}
