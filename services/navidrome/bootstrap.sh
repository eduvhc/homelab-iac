#!/bin/sh
# One-time setup of the Navidrome LXC: installs the binary, creates the
# system user/dirs, sets perms on the mp0 music volume. Idempotent.
# Config (navidrome.toml) is pushed by sync.sh after.
#
# Auth model: reverse-proxy via Authelia at music.${HOMELAB_DOMAIN}.
#   - Caddy on the gateway runs forward_auth → injects Remote-User header.
#   - Navidrome (ND_REVERSEPROXYWHITELIST + ND_REVERSEPROXYUSERHEADER)
#     trusts the gateway IP and creates the user on first request.
#
# Storage layout (set in services/navidrome/lxc.yaml):
#   /var/lib/navidrome              — rootfs (DB, config, native DB backups)
#   /var/lib/navidrome/music        — mp0 (FLAC library, vzdump excluded)
set -e

export DEBIAN_FRONTEND=noninteractive
apt-get update -qq
apt-get install -y -qq curl ca-certificates jq tar sqlite3 gettext-base >/dev/null

if [ ! -x /usr/local/bin/navidrome ]; then
  echo "==> installing Navidrome"
  NVER=$(curl -fsSL https://api.github.com/repos/navidrome/navidrome/releases/latest | jq -r .tag_name)
  # Tag is "v0.60.3" → release asset is "navidrome_0.60.3_linux_amd64.tar.gz".
  NVER_NUM=${NVER#v}
  curl -fsSL "https://github.com/navidrome/navidrome/releases/download/${NVER}/navidrome_${NVER_NUM}_linux_amd64.tar.gz" \
    -o /tmp/navidrome.tgz
  tar -xzf /tmp/navidrome.tgz -C /tmp navidrome
  install -m 0755 /tmp/navidrome /usr/local/bin/navidrome
  rm -f /tmp/navidrome.tgz /tmp/navidrome
fi

# System user + dirs. Music dir is a separate volume (mp0); it exists already
# at mount time, but be defensive and ensure perms after a fresh provision
# (the mount point is created by PVE owned by root:root).
id navidrome >/dev/null 2>&1 || \
  useradd --system --no-create-home --shell /usr/sbin/nologin --home-dir /var/lib/navidrome navidrome

install -d -o navidrome -g navidrome -m 0750 /etc/navidrome
install -d -o navidrome -g navidrome -m 0750 /var/lib/navidrome
install -d -o navidrome -g navidrome -m 0750 /var/lib/navidrome/backups
install -d -o navidrome -g navidrome -m 0755 /var/lib/navidrome/music

systemctl daemon-reload
systemctl enable navidrome >/dev/null 2>&1 || true
echo "==> navidrome bootstrap complete. Now push config:"
echo "    services/navidrome/sync.sh"
