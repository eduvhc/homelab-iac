# Declarative LXC definitions. Container specs come from local.lxcs (see locals.tf).
# LXC 101 (ops) is NOT here — it's where tofu runs.

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
  # Canonical post-import workaround per bpg upstream issue #2901.
  lifecycle {
    ignore_changes = [
      operating_system[0].template_file_id,
      initialization[0].user_account,
      network_interface[0].mac_address,
    ]
  }
}
