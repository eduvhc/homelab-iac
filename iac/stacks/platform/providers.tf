terraform {
  required_version = ">= 1.7"

  required_providers {
    bitwarden-secrets = {
      source  = "bitwarden/bitwarden-secrets"
      version = "~> 1.0"
    }
    tls = {
      source  = "hashicorp/tls"
      version = "~> 4.0"
    }
  }

  # Same encryption as infra stack — both use TF_VAR_tf_state_passphrase.
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
    # Decryption for data.terraform_remote_state.infra (../infra/terraform.tfstate).
    # Both stacks use the same PBKDF2/AES-GCM with the same passphrase.
    remote_state_data_sources {
      default {
        method = method.aes_gcm.main
      }
    }
  }
}

provider "bitwarden-secrets" {}
