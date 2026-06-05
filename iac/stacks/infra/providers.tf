terraform {
  required_version = ">= 1.7"

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
      version = "~> 0.94"
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
  endpoint  = "https://192.168.50.53:8006/"
  api_token = local.pve_api_token
  insecure  = true

  ssh {
    agent       = false
    username    = "root"
    private_key = file("/root/.ssh/id_ed25519")
  }
}
