#!/bin/sh
# One-time setup of an Authelia LXC. Idempotent.
# Run on the target host (192.168.50.40) as root.
set -e

# 1. Authelia user + dirs
id authelia >/dev/null 2>&1 || useradd --system --no-create-home --shell /usr/sbin/nologin authelia
mkdir -p /etc/authelia/secrets /var/lib/authelia /var/log/authelia
chown -R authelia:authelia /etc/authelia /var/lib/authelia /var/log/authelia
chmod 750 /etc/authelia

# 2. Generate internal secrets if missing
if [ ! -s /etc/authelia/secrets.env ]; then
  JWT=$(tr -dc "A-Za-z0-9" </dev/urandom | head -c 64)
  SESS=$(tr -dc "A-Za-z0-9" </dev/urandom | head -c 64)
  STOR=$(tr -dc "A-Za-z0-9" </dev/urandom | head -c 64)
  HMAC=$(tr -dc "A-Za-z0-9" </dev/urandom | head -c 80)
  cat > /etc/authelia/secrets.env <<SECRETS
AUTHELIA_IDENTITY_VALIDATION_RESET_PASSWORD_JWT_SECRET=$JWT
AUTHELIA_SESSION_SECRET=$SESS
AUTHELIA_STORAGE_ENCRYPTION_KEY=$STOR
AUTHELIA_IDENTITY_PROVIDERS_OIDC_HMAC_SECRET=$HMAC
SECRETS
  chmod 600 /etc/authelia/secrets.env
  chown authelia:authelia /etc/authelia/secrets.env
  echo "secrets.env generated"
fi

# 3. Generate OIDC RSA key pair if missing
if [ ! -s /etc/authelia/oidc-private.pem ]; then
  authelia crypto pair rsa generate --directory /etc/authelia/ >/dev/null
  mv /etc/authelia/private.pem /etc/authelia/oidc-private.pem
  mv /etc/authelia/public.pem /etc/authelia/oidc-public.pem
  chown authelia:authelia /etc/authelia/oidc-*.pem
  chmod 640 /etc/authelia/oidc-*.pem
  echo "OIDC RSA pair generated"
fi

# 4. Install systemd unit (idempotent) - actual config files come via sync.sh
systemctl daemon-reload
systemctl enable authelia >/dev/null 2>&1

echo "bootstrap complete - now push configs with sync.sh"
