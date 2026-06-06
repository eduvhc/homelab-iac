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

# Single source of truth: subdomain -> upstream behind the tunnel.
# DNS records and ingress rules are both derived from this map, so adding a
# new subdomain is a one-line edit.
locals {
  tunnel_routes = {
    coolify = "http://localhost:8000"          # Coolify UI (Coolify LXC :8000)
    auth    = "http://${local.ips.gateway}:80" # Authelia UI
    adguard = "http://${local.ips.gateway}:80" # AdGuard admin UI (SSO via Caddy)
  }

  # Wildcard handles every other hostname (apps deployed by Coolify's Traefik).
  tunnel_wildcard_service = "http://localhost:80"

  # DNS records: every named route + the wildcard.
  tunnel_hostnames = toset(concat(keys(local.tunnel_routes), ["*"]))
}

resource "cloudflare_zero_trust_tunnel_cloudflared_config" "coolify" {
  account_id = local.cf_account_id
  tunnel_id  = cloudflare_zero_trust_tunnel_cloudflared.coolify.id

  config = {
    ingress = concat(
      [for name, svc in local.tunnel_routes : {
        hostname = "${name}.${var.domain}"
        service  = svc
      }],
      [
        {
          hostname = "*.${var.domain}"
          service  = local.tunnel_wildcard_service
        },
        {
          service = "http_status:404"
        }
      ]
    )
  }
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
