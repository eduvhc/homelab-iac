output "tunnel_id" {
  value       = cloudflare_zero_trust_tunnel_cloudflared.coolify.id
  description = "Cloudflare tunnel ID."
}

# Tunnel token format: base64(JSON({a:account_tag, t:tunnel_id, s:tunnel_secret}))
output "tunnel_token" {
  value = base64encode(jsonencode({
    a = cloudflare_zero_trust_tunnel_cloudflared.coolify.account_tag
    t = cloudflare_zero_trust_tunnel_cloudflared.coolify.id
    s = random_id.coolify_tunnel_secret.b64_std
  }))
  sensitive   = true
  description = "Use on the Coolify LXC: cloudflared service install <token>. Retrieve with: tofu output -raw tunnel_token"
}
