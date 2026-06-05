data "bitwarden-secrets_list_secrets" "all" {}

locals {
  bws_ids = { for s in data.bitwarden-secrets_list_secrets.all.secrets : s.key => s.id }
}

data "bitwarden-secrets_secret" "cf_api_token" {
  id = local.bws_ids[var.bws_keys.cf_api_token]
}

locals {
  cf_api_token = data.bitwarden-secrets_secret.cf_api_token.value
}
