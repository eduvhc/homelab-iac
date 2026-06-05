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
        hostname = "auth.${var.domain}"
        service  = "http://${local.ips.gateway}:80"
      },
      {
        hostname = "adguard.${var.domain}"
        service  = "http://${local.ips.gateway}:80"
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

# All hostnames that the tunnel handles. Specific records are required for
# each hostname referenced in the tunnel ingress; the wildcard catches the rest
# (Coolify-deployed apps).
locals {
  tunnel_hostnames = toset([
    "coolify",   # Coolify UI (Coolify LXC :8000)
    "auth",      # Authelia UI (gateway LXC :80)
    "adguard",   # AdGuard admin UI (proxied via gateway LXC with SSO)
    "*",         # wildcard for Coolify-deployed apps
  ])
}

resource "cloudflare_dns_record" "tunnel" {
  for_each = local.tunnel_hostnames
  zone_id  = local.cf_zone_id
  name     = each.value
  type     = "CNAME"
  content  = "${cloudflare_zero_trust_tunnel_cloudflared.coolify.id}.cfargotunnel.com"
  ttl      = 1
  proxied  = true
}
