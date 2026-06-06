# Read outputs from the infra stack (state lives in the same R2 bucket under
# infra/terraform.tfstate; same encryption passphrase via providers.tf
# encryption block — see remote_state_data_sources in that file).
data "terraform_remote_state" "infra" {
  backend = "s3"
  config = {
    bucket                      = "homelab-iac-state"
    key                         = "infra/terraform.tfstate"
    region                      = "auto"
    skip_credentials_validation = true
    skip_metadata_api_check     = true
    skip_region_validation      = true
    skip_requesting_account_id  = true
    skip_s3_checksum            = true
  }
}

# Convenience locals so the rest of this stack reads naturally.
locals {
  ips             = data.terraform_remote_state.infra.outputs.lxc_ips
  coolify_api_url = data.terraform_remote_state.infra.outputs.coolify_api_url
}
