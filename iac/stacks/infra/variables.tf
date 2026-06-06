variable "tf_state_passphrase" {
  type        = string
  sensitive   = true
  description = "Passphrase for OpenTofu state encryption. Fetched from BWS by .envrc, exported as TF_VAR_tf_state_passphrase."
}

variable "domain" {
  type        = string
  default     = "iedora.com"
  description = "Root domain managed by this config."
}

variable "proxmox_ssh_key_path" {
  type        = string
  default     = "/root/.ssh/id_ed25519"
  description = "Path to the SSH private key the bpg/proxmox provider uses to SSH into PVE. Override in CI with a dummy path so `tofu validate` doesn't fail on missing /root/.ssh/."
}

variable "bws_keys" {
  type = object({
    cf_api_token      = string
    pve_root_password = string
  })
  default = {
    cf_api_token      = "CLOUDFLARE_API_TOKEN"
    pve_root_password = "PVE_ROOT_PASSWORD"
  }
  description = "Names of the BWS secrets to look up (in project: homelab)."
}
