# Cloudflare zone lookup (single source for account_id + zone_id; the API
# token must be scoped to this zone).
data "cloudflare_zone" "homelab" {
  filter = {
    name = var.domain
  }
}

locals {
  cf_account_id = data.cloudflare_zone.homelab.account.id
  cf_zone_id    = data.cloudflare_zone.homelab.id
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
# and split into named + wildcard. The wildcard (hostname: "*") must come
# LAST in the ingress array, before the 404 fallback.
#
# Upstreams resolve service names via network/ips.yaml; "localhost" is
# accepted but discouraged with cloudflared HA (only works on the host
# where the upstream actually listens).
locals {
  _route_files = fileset("${path.module}/../../..", "services/*/tunnel-routes.yaml")
  _routes_raw = flatten([
    for f in local._route_files :
    yamldecode(file("${path.module}/../../../${f}"))
  ])

  _named_routes = { for r in local._routes_raw : r.hostname => r if r.hostname != "*" }
  _wildcards    = [for r in local._routes_raw : r if r.hostname == "*"]

  tunnel_routes = {
    for h, r in local._named_routes :
    h => (
      r.upstream.host == "localhost"
      ? "http://localhost:${r.upstream.port}"
      : "http://${local.ips[r.upstream.host]}:${r.upstream.port}"
    )
  }

  # Exactly-one wildcard expected. If absent → no catch-all, just 404 fallback.
  _wildcard_service = length(local._wildcards) == 0 ? null : (
    local._wildcards[0].upstream.host == "localhost"
    ? "http://localhost:${local._wildcards[0].upstream.port}"
    : "http://${local.ips[local._wildcards[0].upstream.host]}:${local._wildcards[0].upstream.port}"
  )

  # DNS records: every named route + the wildcard (if any).
  tunnel_hostnames = toset(
    concat(keys(local.tunnel_routes), local._wildcard_service == null ? [] : ["*"])
  )
}

# Two-or-more wildcards = ambiguous routing. Catch at plan time.
check "single_wildcard" {
  assert {
    condition     = length(local._wildcards) <= 1
    error_message = "More than one services/*/tunnel-routes.yaml declares `hostname: \"*\"`. Only one wildcard is allowed."
  }
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
      local._wildcard_service == null ? [] : [{
        hostname = "*.${var.domain}"
        service  = local._wildcard_service
      }],
      [{ service = "http_status:404" }]
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
