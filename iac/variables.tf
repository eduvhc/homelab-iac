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

variable "bws_keys" {
  type = object({
    cf_api_token      = string
    coolify_api_token = string
  })
  default = {
    cf_api_token      = "CLOUDFLARE_API_TOKEN"
    coolify_api_token = "COOLIFY_API_TOKEN"
  }
  description = "Names of the BWS secrets to look up (in project: homelab)."
}
