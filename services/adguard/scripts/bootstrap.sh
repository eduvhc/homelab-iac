#!/bin/sh
# One-time setup of an AdGuard Home LXC.
# Installs the AGH binary + creates the directory; idempotent.
# Configuration is then pushed via the sync engine (services/<svc>/sync.yaml).
set -e

export DEBIAN_FRONTEND=noninteractive
apt-get update -qq
apt-get install -y -qq curl ca-certificates nftables python3-yaml

if [ -x /opt/AdGuardHome/AdGuardHome ]; then
  echo "AdGuardHome already installed"
  exit 0
fi

# Official install script — clean, idempotent, downloads latest stable
curl -fsSL https://raw.githubusercontent.com/AdguardTeam/AdGuardHome/master/scripts/install.sh -o /tmp/install.sh
sh /tmp/install.sh -r >/dev/null
rm -f /tmp/install.sh

# Stop immediately - config will be pushed by the sync engine (services/<svc>/sync.yaml) before we want it running
systemctl stop AdGuardHome
echo "AdGuardHome installed; sync engine will push config"
