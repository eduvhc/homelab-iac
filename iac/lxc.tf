# Declarative LXC definitions. LXC 101 (ops) is NOT here — it's where tofu runs,
# so it has to bootstrap manually. Everything else: tofu apply creates the LXC
# at the right node with the right resources/tags.

locals {
  pve_node = "pve"

  lxcs = {
    adguard = {
      vm_id     = 102
      hostname  = "adguard"
      ip        = "192.168.50.30/24"
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
      ip        = "192.168.50.40/24"
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
      ip        = "192.168.50.200/24"
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
      ip        = "192.168.50.210/24"
      cores     = 2
      memory_mb = 4096
      swap_mb   = 1024
      disk_gb   = 30
      tags      = ["coolify", "runtime"]
      features  = { nesting = true, keyctl = true }
    }
  }
}

resource "proxmox_virtual_environment_container" "lxc" {
  for_each = local.lxcs

  vm_id     = each.value.vm_id
  node_name = local.pve_node
  tags      = each.value.tags

  unprivileged  = true
  start_on_boot = true
  started       = true

  initialization {
    hostname = each.value.hostname
    ip_config {
      ipv4 {
        address = each.value.ip
        gateway = "192.168.50.1"
      }
    }
    dns {
      servers = ["1.1.1.1", "1.0.0.1"]
    }
  }

  cpu {
    cores = each.value.cores
  }

  memory {
    dedicated = each.value.memory_mb
    swap      = each.value.swap_mb
  }

  disk {
    datastore_id = "local-lvm"
    size         = each.value.disk_gb
  }

  features {
    nesting = each.value.features.nesting
    keyctl  = each.value.features.keyctl
  }

  network_interface {
    name   = "eth0"
    bridge = "vmbr0"
  }

  operating_system {
    template_file_id = "local:vztmpl/debian-13-standard_13.1-2_amd64.tar.zst"
    type             = "debian"
  }

  # template_file_id and SSH keys are one-shot create attributes; importing
  # an existing LXC shows them as "to be added" which would force replacement.
  # Ignore drift on these so the resource stays in sync without recreate.
  lifecycle {
    ignore_changes = [
      operating_system[0].template_file_id,
      initialization[0].user_account,
      network_interface[0].mac_address,
    ]
  }
}
