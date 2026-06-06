terraform {
  # 1.12 (2026-05): dynamic prevent_destroy, destroy=false lifecycle,
  # faster concurrent provider installs.
  required_version = ">= 1.12"

  required_providers {
    cloudflare = {
      source  = "cloudflare/cloudflare"
      version = "~> 5.0"
    }
    random = {
      source  = "hashicorp/random"
      version = "~> 3.6"
    }
    bitwarden-secrets = {
      source  = "bitwarden/bitwarden-secrets"
      version = "~> 1.0"
    }
    proxmox = {
      source  = "bpg/proxmox"
      version = "~> 0.108"
    }
  }

  encryption {
    key_provider "pbkdf2" "main" {
      passphrase = var.tf_state_passphrase
    }
    method "aes_gcm" "main" {
      keys = key_provider.pbkdf2.main
    }
    state {
      method = method.aes_gcm.main
    }
    plan {
      method = method.aes_gcm.main
    }
  }
}

provider "bitwarden-secrets" {}

provider "cloudflare" {
  api_token = local.cf_api_token
}

provider "proxmox" {
  endpoint = "https://192.168.50.53:8006/"
  # Using username + password (not API token) because PVE has a hardcoded
  # restriction: tokens cannot change LXC feature flags other than `nesting`.
  # Coolify + runner LXCs need `keyctl=1` for Docker, which requires root@pam.
  # privsep=0 tokens were already root-equivalent in our setup, so this is
  # the same posture without the hidden cliff.
  username = "root@pam"
  password = local.pve_root_password
  insecure = true # self-signed cert from PVE installer

  ssh {
    agent       = false
    username    = "root"
    private_key = file("/root/.ssh/id_ed25519")
  }
}
