output "tunnel_id" {
  value       = cloudflare_zero_trust_tunnel_cloudflared.coolify.id
  description = "Cloudflare tunnel ID."
}

output "tunnel_token" {
  value = base64encode(jsonencode({
    a = cloudflare_zero_trust_tunnel_cloudflared.coolify.account_tag
    t = cloudflare_zero_trust_tunnel_cloudflared.coolify.id
    s = random_id.coolify_tunnel_secret.b64_std
  }))
  sensitive   = true
  description = "Use on the Coolify LXC: cloudflared service install <token>. Retrieve with: tofu output -raw tunnel_token"
}

output "lxc_ips" {
  value       = local.ips
  description = "Map of LXC name -> IP address. Useful for shell scripts AND for the platform stack via terraform_remote_state."
}

output "coolify_api_url" {
  value       = local.coolify_api_url
  description = "Internal HTTP URL of the Coolify API. Consumed by the platform stack."
}

output "network" {
  value = {
    lan_cidr    = local.lan_cidr
    lan_gateway = local.lan_gateway
  }
  description = "Network constants. Consumed by tools/lib/lxc-ips.sh for envsubst-templated config files (nftables.conf.tmpl, etc.)."
}
