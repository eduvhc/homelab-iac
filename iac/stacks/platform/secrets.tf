data "bitwarden-secrets_list_secrets" "all" {}

locals {
  bws_ids = { for s in data.bitwarden-secrets_list_secrets.all.secrets : s.key => s.id }
}

data "bitwarden-secrets_secret" "coolify_api_token" {
  id = local.bws_ids[var.bws_keys.coolify_api_token]
}

locals {
  coolify_api_token = data.bitwarden-secrets_secret.coolify_api_token.value
}
