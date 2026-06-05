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

# All BWS config via env vars (BW_ACCESS_TOKEN, BW_ORGANIZATION_ID,
# BW_API_URL, BW_IDENTITY_API_URL). Set in .envrc.
provider "bitwarden-secrets" {}

provider "cloudflare" {
  api_token = local.cf_api_token
}
