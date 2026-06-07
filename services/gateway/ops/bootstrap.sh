#!/bin/sh
# One-time setup of a gateway LXC: installs Caddy + Authelia binaries +
# generates Authelia internal secrets/RSA pair. Idempotent.
# Config (Caddyfile, configuration.yml, users_database.yml) is pushed
# via the sync engine (caddy/sync.yaml + authelia/scripts/sync.sh hybrid) after.
set -e

export DEBIAN_FRONTEND=noninteractive
apt-get update -qq
apt-get install -y -qq curl ca-certificates gnupg jq sqlite3 debian-keyring debian-archive-keyring apt-transport-https >/dev/null

if ! command -v caddy >/dev/null; then
  echo "==> installing Caddy"
  curl -fsSL https://dl.cloudsmith.io/public/caddy/stable/gpg.key \
    | gpg --dearmor -o /usr/share/keyrings/caddy-stable-archive-keyring.gpg
  echo "deb [signed-by=/usr/share/keyrings/caddy-stable-archive-keyring.gpg] https://dl.cloudsmith.io/public/caddy/stable/deb/debian any-version main" \
    > /etc/apt/sources.list.d/caddy-stable.list
  apt-get update -qq
  apt-get install -y -qq caddy >/dev/null
fi

if [ ! -x /usr/local/bin/authelia ]; then
  echo "==> installing Authelia"
  AVER=$(curl -fsSL https://api.github.com/repos/authelia/authelia/releases/latest | jq -r .tag_name)
  curl -fsSL "https://github.com/authelia/authelia/releases/download/${AVER}/authelia-${AVER}-linux-amd64.tar.gz" \
    -o /tmp/authelia.tgz
  tar -xzf /tmp/authelia.tgz -C /tmp
  install -m 0755 /tmp/authelia /usr/local/bin/authelia
fi

# Authelia user + dirs (idempotent)
id authelia >/dev/null 2>&1 || useradd --system --no-create-home --shell /usr/sbin/nologin authelia
mkdir -p /etc/authelia /var/lib/authelia /var/log/authelia
chown -R authelia:authelia /etc/authelia /var/lib/authelia /var/log/authelia
chmod 750 /etc/authelia

# Caddy log directory (Caddyfile writes JSON access log here with zstd rolling).
# Created by deb package only for /var/log/caddy/access.log itself — be defensive.
install -d -o caddy -g caddy -m 0750 /var/log/caddy

if [ ! -s /etc/authelia/secrets.env ]; then
  JWT=$(tr -dc A-Za-z0-9 </dev/urandom | head -c 64)
  SESS=$(tr -dc A-Za-z0-9 </dev/urandom | head -c 64)
  STOR=$(tr -dc A-Za-z0-9 </dev/urandom | head -c 64)
  HMAC=$(tr -dc A-Za-z0-9 </dev/urandom | head -c 80)
  cat > /etc/authelia/secrets.env <<SECRETS
AUTHELIA_IDENTITY_VALIDATION_RESET_PASSWORD_JWT_SECRET=$JWT
AUTHELIA_SESSION_SECRET=$SESS
AUTHELIA_STORAGE_ENCRYPTION_KEY=$STOR
AUTHELIA_IDENTITY_PROVIDERS_OIDC_HMAC_SECRET=$HMAC
SECRETS
  chmod 600 /etc/authelia/secrets.env
  chown authelia:authelia /etc/authelia/secrets.env
fi

if [ ! -s /etc/authelia/oidc-private.pem ]; then
  /usr/local/bin/authelia crypto pair rsa generate --directory /etc/authelia/ >/dev/null
  mv /etc/authelia/private.pem /etc/authelia/oidc-private.pem
  mv /etc/authelia/public.pem  /etc/authelia/oidc-public.pem
  chown authelia:authelia /etc/authelia/oidc-*.pem
  chmod 640 /etc/authelia/oidc-*.pem
fi

systemctl daemon-reload
systemctl enable caddy >/dev/null 2>&1
systemctl enable authelia >/dev/null 2>&1 || true
echo "==> gateway bootstrap complete. Now push configs:"
echo "    services/gateway/authelia/ops/sync.sh (hybrid hash + sync engine)"
echo "    sync_service gateway/caddy (or tools/apply.sh)"
