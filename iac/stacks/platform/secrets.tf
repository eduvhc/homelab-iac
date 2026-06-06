# Secrets come from iac/secrets.sops.yaml, decrypted by iac/.envrc on shell
# source and exposed as TF_VAR_* env vars. See variables.tf for declarations.
locals {
  coolify_api_token = var.coolify_api_token
}
