# Secrets come from iac/secrets.sops.yaml, decrypted by iac/.envrc on shell
# source and exposed as TF_VAR_* env vars. Tofu sees them as regular sensitive
# variables — see variables.tf for declarations.
locals {
  cf_api_token      = var.cf_api_token
  pve_root_password = var.pve_root_password
}
