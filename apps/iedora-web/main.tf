# External infrastructure for iedora-web — Cloudflare R2 bucket for user
# uploads + bucket-scoped S3-compatible credentials. The Coolify-side
# Application reads these as S3_* env vars (set manually in Coolify UI;
# see README for the values to paste).

# ── Variables ──────────────────────────────────────────────────────────────
variable "tf_state_passphrase" {
  type        = string
  sensitive   = true
  description = "Decrypts/encrypts the tofu state for this app. Sourced from iac/secrets.sops.yaml via .envrc → TF_VAR_tf_state_passphrase."
}

variable "cf_api_token" {
  type        = string
  sensitive   = true
  description = "Cloudflare API token. Same as the infra stack — sourced from sops via .envrc → TF_VAR_cf_api_token."
}

variable "r2_account_id" {
  type        = string
  description = "Cloudflare account ID for R2. Sourced from iac/.envrc → TF_VAR_r2_account_id (non-secret identifier)."
}

variable "bucket_name" {
  type        = string
  default     = "iedora-assets"
  description = "R2 bucket name for app uploads. Globally unique per CF account."
}

variable "cors_origins" {
  type = list(string)
  default = [
    "https://iedora.com",
    "https://menu.iedora.com",
    "https://core.iedora.com",
    "https://imopush.iedora.com",
  ]
  description = "Browser origins authorized to PUT/POST directly to the bucket (signed URLs from the app)."
}

# ── Bucket + CORS ──────────────────────────────────────────────────────────
resource "cloudflare_r2_bucket" "assets" {
  account_id    = var.r2_account_id
  name          = var.bucket_name
  location      = "weur"
  storage_class = "Standard"
}

resource "cloudflare_r2_bucket_cors" "assets" {
  account_id  = var.r2_account_id
  bucket_name = cloudflare_r2_bucket.assets.name
  rules = [{
    allowed = {
      methods = ["GET", "PUT", "POST", "HEAD"]
      origins = var.cors_origins
      headers = ["*"]
    }
    max_age_seconds = 3600
  }]
}

# ── Bucket-scoped S3-compatible token ──────────────────────────────────────
# CF has no dedicated R2 token endpoint; /user/tokens returns a generic CF
# token that, per CF convention, is consumed as S3 creds via:
#   access_key_id     = token.id
#   secret_access_key = sha256(token.value)
data "cloudflare_api_token_permission_groups_list" "all" {}

locals {
  r2_read_pg_id = one([
    for pg in data.cloudflare_api_token_permission_groups_list.all.result :
    pg.id if pg.name == "Workers R2 Storage Bucket Item Read"
  ])
  r2_write_pg_id = one([
    for pg in data.cloudflare_api_token_permission_groups_list.all.result :
    pg.id if pg.name == "Workers R2 Storage Bucket Item Write"
  ])
}

resource "cloudflare_api_token" "assets_rw" {
  name = "iedora-web-assets-rw"
  policies = [{
    effect = "allow"
    permission_groups = [
      { id = local.r2_read_pg_id },
      { id = local.r2_write_pg_id },
    ]
    resources = jsonencode({
      "com.cloudflare.edge.r2.bucket.${var.r2_account_id}_default_${var.bucket_name}" = "*"
    })
  }]
}

# ── Outputs (paste into Coolify UI as env vars) ────────────────────────────
output "s3_endpoint" {
  value       = "https://${var.r2_account_id}.r2.cloudflarestorage.com"
  description = "Set as S3_ENDPOINT in the iedora-web Coolify app."
}

output "s3_bucket" {
  value       = cloudflare_r2_bucket.assets.name
  description = "Set as S3_BUCKET in the iedora-web Coolify app."
}

output "s3_region" {
  value       = "auto"
  description = "Set as S3_REGION in the iedora-web Coolify app."
}

output "s3_access_key_id" {
  value       = cloudflare_api_token.assets_rw.id
  sensitive   = true
  description = "Set as S3_ACCESS_KEY in the iedora-web Coolify app. Reveal: tofu output -raw s3_access_key_id"
}

output "s3_secret_access_key" {
  value       = sha256(cloudflare_api_token.assets_rw.value)
  sensitive   = true
  description = "Set as S3_SECRET_KEY in the iedora-web Coolify app. Reveal: tofu output -raw s3_secret_access_key"
}
