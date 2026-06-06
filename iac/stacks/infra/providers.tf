terraform {
  # 1.12 (2026-05): dynamic prevent_destroy, destroy=false lifecycle,
  # faster concurrent provider installs.
  required_version = ">= 1.12"

  # State lives in a Cloudflare R2 bucket (S3-compatible). Native
  # use_lockfile (OpenTofu 1.10+) replaces DynamoDB. Endpoint, creds,
  # and region come from AWS_* env vars set by iac/.envrc (which
  # decrypts them from iac/secrets.sops.yaml via age). State is still
  # encrypted by the encryption{} block below — defense in depth if R2
  # keys leak.
  backend "s3" {
    bucket                      = "iedora-iac-state"
    key                         = "infra/terraform.tfstate"
    region                      = "auto"
    use_lockfile                = true
    encrypt                     = false # we use the encryption{} block, not SSE
    skip_credentials_validation = true
    skip_metadata_api_check     = true
    skip_region_validation      = true
    skip_requesting_account_id  = true
    skip_s3_checksum            = true
  }

  required_providers {
    cloudflare = {
      source  = "cloudflare/cloudflare"
      version = "~> 5.0"
    }
    random = {
      source  = "hashicorp/random"
      version = "~> 3.6"
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
    private_key = file(var.proxmox_ssh_key_path)
  }
}
