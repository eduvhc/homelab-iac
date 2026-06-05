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
  description = "Map of LXC name -> IP address. Useful for shell scripts: tofu output -json lxc_ips | jq -r .coolify"
}

output "coolify_runner_public_key" {
  value       = trimspace(tls_private_key.coolify_runner_key.public_key_openssh)
  description = "ED25519 public key that Coolify uses to SSH into runners. If a runner LXC ever loses its authorized_keys, paste this back in."
}
