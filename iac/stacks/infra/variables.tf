variable "tf_state_passphrase" {
  type        = string
  sensitive   = true
  description = "Passphrase for OpenTofu state encryption. Decrypted from iac/secrets.sops.yaml by .envrc, exported as TF_VAR_tf_state_passphrase."
}

variable "cf_api_token" {
  type        = string
  sensitive   = true
  description = "Cloudflare API token. Decrypted from iac/secrets.sops.yaml by .envrc, exported as TF_VAR_cf_api_token."
}

variable "pve_root_password" {
  type        = string
  sensitive   = true
  description = "PVE root@pam password. Decrypted from iac/secrets.sops.yaml by .envrc, exported as TF_VAR_pve_root_password."
}

variable "domain" {
  type        = string
  description = "Root domain managed by this config. Set from HOMELAB_DOMAIN in iac/secrets.sops.yaml via source_envrc → TF_VAR_domain."
}

variable "proxmox_ssh_key_path" {
  type        = string
  default     = "/root/.ssh/id_ed25519"
  description = "Path to the SSH private key the bpg/proxmox provider uses to SSH into PVE. Override in CI with a dummy path so `tofu validate` doesn't fail on missing /root/.ssh/."
}
