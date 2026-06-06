#!/bin/sh
# One-time setup of a coolify-runner LXC: install Docker so Coolify can deploy here.
# Run on the target LXC (e.g. 192.168.50.210) as root. Idempotent.
set -e

# Already have Docker? bail
if command -v docker >/dev/null && docker info >/dev/null 2>&1; then
  echo "docker already installed and running"
  exit 0
fi

export DEBIAN_FRONTEND=noninteractive
apt-get update -qq
apt-get install -y -qq curl ca-certificates

# Use the official Docker convenience script — matches what Coolify would do
curl -fsSL https://get.docker.com -o /tmp/get-docker.sh
sh /tmp/get-docker.sh
rm /tmp/get-docker.sh

systemctl enable --now docker
docker --version
docker compose version || true
