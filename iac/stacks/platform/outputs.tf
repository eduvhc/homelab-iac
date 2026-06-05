output "coolify_runner_public_key" {
  value       = trimspace(tls_private_key.coolify_runner_key.public_key_openssh)
  description = "ED25519 public key Coolify uses to SSH into runners. If a runner LXC ever loses its authorized_keys, paste this back in."
}
