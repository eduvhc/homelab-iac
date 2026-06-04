# Look up zone (and its account) once - eliminates need to store ids elsewhere.
# Requires the CF API token to be scoped to this zone+account.
data "cloudflare_zone" "iedora" {
  filter = {
    name = var.domain
  }
}

locals {
  cf_account_id = data.cloudflare_zone.iedora.account.id
  cf_zone_id    = data.cloudflare_zone.iedora.id
}

resource "random_id" "coolify_tunnel_secret" {
  byte_length = 32
}

resource "cloudflare_zero_trust_tunnel_cloudflared" "coolify" {
  account_id    = local.cf_account_id
  name          = "coolify-iedora"
  tunnel_secret = random_id.coolify_tunnel_secret.b64_std
}

resource "cloudflare_zero_trust_tunnel_cloudflared_config" "coolify" {
  account_id = local.cf_account_id
  tunnel_id  = cloudflare_zero_trust_tunnel_cloudflared.coolify.id

  config = {
    ingress = [
      {
        hostname = "coolify.${var.domain}"
        service  = "http://localhost:8000"
      },
      {
        hostname = "*.${var.domain}"
        service  = "http://localhost:80"
      },
      {
        service = "http_status:404"
      }
    ]
  }
}

resource "cloudflare_dns_record" "coolify_ui" {
  zone_id = local.cf_zone_id
  name    = "coolify"
  type    = "CNAME"
  content = "${cloudflare_zero_trust_tunnel_cloudflared.coolify.id}.cfargotunnel.com"
  ttl     = 1
  proxied = true
}

resource "cloudflare_dns_record" "apps_wildcard" {
  zone_id = local.cf_zone_id
  name    = "*"
  type    = "CNAME"
  content = "${cloudflare_zero_trust_tunnel_cloudflared.coolify.id}.cfargotunnel.com"
  ttl     = 1
  proxied = true
}
