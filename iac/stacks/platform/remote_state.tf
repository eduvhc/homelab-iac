# Read outputs from the infra stack (../infra/terraform.tfstate, encrypted with
# the same passphrase via providers.tf encryption block).
data "terraform_remote_state" "infra" {
  backend = "local"
  config = {
    path = "../infra/terraform.tfstate"
  }
}

# Convenience locals so the rest of this stack reads naturally.
locals {
  ips             = data.terraform_remote_state.infra.outputs.lxc_ips
  coolify_api_url = data.terraform_remote_state.infra.outputs.coolify_api_url
}
