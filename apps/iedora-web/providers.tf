terraform {
  required_version = ">= 1.12"

  # Own state file, scoped under apps/iedora-web/ in the shared R2 bucket.
  # Adding a new app means a new folder with its own backend key — no
  # cross-app state coupling.
  backend "s3" {
    bucket                      = "iedora-iac-state"
    key                         = "apps/iedora-web/terraform.tfstate"
    region                      = "auto"
    use_lockfile                = true
    encrypt                     = false # PBKDF2-AES-GCM via encryption{} below
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
  api_token = var.cf_api_token
}
