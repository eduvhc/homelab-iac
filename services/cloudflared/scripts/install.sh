#!/bin/sh
# Idempotently install + start cloudflared on the current host using the
# remotely-managed tunnel token. The token is stored in /etc/cloudflared/token
# (mode 0600) and read by the systemd unit at start — never appears on
# argv where `ps` could see it.
#
# Run remotely:
#   ssh root@HOST "TUNNEL_TOKEN=... sh -s" < services/cloudflared/scripts/install.sh
#
# Re-running is safe: package install is a no-op when present, token file is
# overwritten only if changed, and the service is reloaded only when needed.

set -e

: "${TUNNEL_TOKEN:?TUNNEL_TOKEN must be set in env before running this script}"

export DEBIAN_FRONTEND=noninteractive

# Repo + package (idempotent).
if ! command -v cloudflared >/dev/null; then
  apt-get update -qq
  apt-get install -y -qq curl ca-certificates gnupg
  install -d -m 0755 /usr/share/keyrings
  if [ ! -s /usr/share/keyrings/cloudflare-main.gpg ]; then
    curl -fsSL https://pkg.cloudflare.com/cloudflare-main.gpg \
      -o /usr/share/keyrings/cloudflare-main.gpg
  fi
  if [ ! -s /etc/apt/sources.list.d/cloudflared.list ]; then
    echo 'deb [signed-by=/usr/share/keyrings/cloudflare-main.gpg] https://pkg.cloudflare.com/cloudflared bookworm main' \
      > /etc/apt/sources.list.d/cloudflared.list
  fi
  apt-get update -qq
  apt-get install -y -qq cloudflared
fi

# Token file at 0600 so only root reads it.
install -d -m 0700 /etc/cloudflared
NEW_TOKEN_FILE=$(mktemp)
printf '%s\n' "$TUNNEL_TOKEN" > "$NEW_TOKEN_FILE"
chmod 0600 "$NEW_TOKEN_FILE"
if ! cmp -s "$NEW_TOKEN_FILE" /etc/cloudflared/token 2>/dev/null; then
  mv "$NEW_TOKEN_FILE" /etc/cloudflared/token
  TOKEN_CHANGED=1
else
  rm -f "$NEW_TOKEN_FILE"
  TOKEN_CHANGED=0
fi

# systemd unit. Uses ExecStart with --token-file so the token never appears in
# argv (vs `cloudflared service install <token>` which bakes it into the unit).
UNIT=/etc/systemd/system/cloudflared.service
NEW_UNIT=$(mktemp)
cat > "$NEW_UNIT" <<'EOF'
[Unit]
Description=Cloudflare Tunnel
After=network-online.target
Wants=network-online.target

[Service]
Type=notify
ExecStart=/usr/bin/cloudflared --no-autoupdate tunnel --protocol quic run --token-file /etc/cloudflared/token
Restart=on-failure
RestartSec=5s
TimeoutStopSec=20s
# Hardening
NoNewPrivileges=true
ProtectSystem=strict
ProtectHome=true
PrivateTmp=true

[Install]
WantedBy=multi-user.target
EOF

if ! cmp -s "$NEW_UNIT" "$UNIT" 2>/dev/null; then
  mv "$NEW_UNIT" "$UNIT"
  chmod 0644 "$UNIT"
  systemctl daemon-reload
  UNIT_CHANGED=1
else
  rm -f "$NEW_UNIT"
  UNIT_CHANGED=0
fi

# Disable any legacy unit installed by `cloudflared service install` (it lives
# at /etc/systemd/system/cloudflared.service too, but had the token in argv).
# Our overwrite above already handles that case.

systemctl enable --quiet cloudflared
if ! systemctl is-active --quiet cloudflared || [ "$TOKEN_CHANGED" = 1 ] || [ "$UNIT_CHANGED" = 1 ]; then
  systemctl restart cloudflared
fi

sleep 2
systemctl is-active --quiet cloudflared && echo "cloudflared: active on $(hostname)"
