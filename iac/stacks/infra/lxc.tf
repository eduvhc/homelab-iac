# Declarative LXC definitions. Container specs come from local.lxcs (see locals.tf).
# LXC 101 (ops) is NOT here — it's where tofu runs.

resource "proxmox_virtual_environment_container" "lxc" {
  for_each = local.lxcs

  vm_id     = each.value.vm_id
  node_name = each.value.node
  tags      = each.value.tags

  unprivileged  = true
  start_on_boot = true
  started       = true

  initialization {
    hostname = each.value.hostname
    ip_config {
      ipv4 {
        address = each.value.ip
        gateway = local.lan_gateway
      }
    }
    dns {
      servers = ["1.1.1.1", "1.0.0.1"]
    }
    # On create, install the ops LXC's pubkey so apply.sh + sync.sh can SSH in
    # without manual intervention. ignore_changes (below) prevents post-create
    # diffs from forcing replacement.
    user_account {
      keys = [trimspace(file("${var.proxmox_ssh_key_path}.pub"))]
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

  # Optional extra mount points (mp0, mp1, ...) declared per service in
  # services/<svc>/lxc.yaml under `mount_points:`. Two modes per entry:
  #
  #   size_gb:   allocate a new LVM-thin volume on local-lvm. Per-container,
  #              private, included/excluded from vzdump per `backup:`. Used
  #              for state-vs-media separation when state lives on host SSD.
  #
  #   host_path: bind-mount the given host path into the container. Shared
  #              across LXCs trivially — the same host path can be declared
  #              in multiple services/<svc>/lxc.yaml entries (e.g. Navidrome
  #              + Lidarr + ytdl-sub all see /srv/media/music). bpg emits
  #              these as `mp<n>: /host/path,mp=/in/container`. Bind mounts
  #              require root@pam username+password on the provider (API
  #              tokens are blocked by PVE) — already the case here.
  #
  # Exactly one of size_gb / host_path must be set per entry.
  dynamic "mount_point" {
    for_each = lookup(each.value, "mount_points", [])
    content {
      volume = lookup(mount_point.value, "host_path", null) != null ? mount_point.value.host_path : "local-lvm"
      size   = lookup(mount_point.value, "host_path", null) != null ? null : "${lookup(mount_point.value, "size_gb", 0)}G"
      path   = mount_point.value.path
      backup = lookup(mount_point.value, "backup", true)
    }
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
