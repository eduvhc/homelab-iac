# Cloudflare zone lookup (single source for account_id + zone_id; the API
# token must be scoped to this zone).
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

# Per-service tunnel routes: discover every services/<svc>/tunnel-routes.yaml
# and flatten into a single ingress list. Each entry's upstream is rendered
# via local.ips by service-name (or kept as "localhost" verbatim — used when
# cloudflared shares the LXC with the upstream service).
locals {
  _route_files = fileset("${path.module}/../../..", "services/*/tunnel-routes.yaml")
  _routes_raw = flatten([
    for f in local._route_files :
    yamldecode(file("${path.module}/../../../${f}"))
  ])

  tunnel_routes = {
    for r in local._routes_raw :
    r.hostname => (
      r.upstream.host == "localhost"
      ? "http://localhost:${r.upstream.port}"
      : "http://${local.ips[r.upstream.host]}:${r.upstream.port}"
    )
  }

  # Wildcard: every other subdomain → Coolify's Traefik on the cloudflared host.
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
