variable "tf_state_passphrase" {
  type        = string
  sensitive   = true
  description = "Passphrase for OpenTofu state encryption. Same value as infra stack — fetched from BWS by .envrc."
}

variable "bws_keys" {
  type = object({
    coolify_api_token = string
  })
  default = {
    coolify_api_token = "COOLIFY_API_TOKEN"
  }
  description = "Names of the BWS secrets used by this stack."
}
