terraform {
  required_version = ">= 1.12"

  # R2 backend (see iac/stacks/infra/providers.tf for full rationale).
  # Different `key` keeps the two stacks' state files apart in the bucket.
  backend "s3" {
    bucket                      = "homelab-iac-state"
    key                         = "platform/terraform.tfstate"
    region                      = "auto"
    use_lockfile                = true
    encrypt                     = false
    skip_credentials_validation = true
    skip_metadata_api_check     = true
    skip_region_validation      = true
    skip_requesting_account_id  = true
    skip_s3_checksum            = true
  }

  required_providers {
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
