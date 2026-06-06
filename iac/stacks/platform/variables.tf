variable "tf_state_passphrase" {
  type        = string
  sensitive   = true
  description = "Passphrase for OpenTofu state encryption. Same value as infra stack — decrypted from iac/secrets.sops.yaml by .envrc."
}

variable "coolify_api_token" {
  type        = string
  sensitive   = true
  description = "Coolify API token (format: <id>|<plain>). Decrypted from iac/secrets.sops.yaml by .envrc, exported as TF_VAR_coolify_api_token."
}
