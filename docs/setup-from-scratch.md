# Setup from scratch

End-to-end procedure for rebuilding the iedora homelab on a clean PVE host.

This documents *the actual order of operations*, not an idealized one. Each
LXC has bootstrap and sync scripts in `configs/<svc>/scripts/` — read those
for the per-service mechanics.

## Prerequisites

- A PVE 9.x host with:
  - LAN `192.168.50.0/24`, gateway `.1`
  - Internet outbound
  - Repos on `pve-no-subscription` (not enterprise)
  - SSH key auth for root (`PermitRootLogin prohibit-password`)
- A Bitwarden Secrets Manager (BWS) workspace with a project named `homelab`
- A Cloudflare account with the `iedora.com` zone
- Two BWS items needed BEFORE anything boots:
  - `TOFU_STATE_PASSPHRASE` — `openssl rand -base64 24 | tr -d /+=`
  - `CLOUDFLARE_API_TOKEN` — Custom Token with:
    - Account/Cloudflare Tunnel: Edit
    - Account/Zero Trust: Edit
    - Zone/DNS: Edit (scoped to iedora.com)

Everything else (Coolify admin creds, Coolify API token, OIDC secrets, etc.)
is created by the bootstrap scripts.

## Inventory snapshot

| LXC | Hostname | IP | Tags | Purpose |
|-----|----------|----|------|---------|
| 101 | ops | .101 | infra;iac | Where tofu and bws CLI live, where this repo is cloned |
| 102 | adguard | .30 | infra;dns | AdGuard Home; split-DNS rewrites |
| 103 | gateway | .40 | infra;sso | Caddy + Authelia (SSO for admin UIs) |
| 200 | coolify | .200 | coolify;control-plane | Coolify UI + cloudflared (tunnel terminator) |
| 210 | coolify-runner-01 | .210 | coolify;runtime | Docker engine where deployed apps run |

## Step 0 — Bootstrap the ops LXC

```bash
pct create 101 local:vztmpl/debian-13-standard_13.1-2_amd64.tar.zst \
  --hostname ops --cores 2 --memory 512 --swap 1024 \
  --rootfs local-lvm:10 \
  --net0 name=eth0,bridge=vmbr0,ip=192.168.50.101/24,gw=192.168.50.1 \
  --nameserver "1.1.1.1 9.9.9.9" \
  --unprivileged 1 --onboot 1 --start 1 \
  --ssh-public-keys /tmp/your-mac-key.pub
```

Inside `ops`:
```bash
# Install toolchain
apt update && apt install -y curl gnupg git jq ripgrep

# OpenTofu (apt repo)
curl -fsSL https://packages.opentofu.org/opentofu/tofu/gpgkey | \
  gpg --dearmor -o /usr/share/keyrings/opentofu.gpg
echo "deb [signed-by=/usr/share/keyrings/opentofu.gpg] https://packages.opentofu.org/opentofu/tofu/any/ any main" \
  > /etc/apt/sources.list.d/opentofu.list
apt update && apt install -y tofu

# bws CLI
LATEST=$(curl -fsSL "https://api.github.com/repos/bitwarden/sdk-sm/releases?per_page=50" | \
  jq -r '.[] | select(.tag_name | startswith("bws-v")) | .tag_name' | sort -V | tail -1)
VER=${LATEST#bws-v}
curl -fsSL "https://github.com/bitwarden/sdk-sm/releases/download/${LATEST}/bws-x86_64-unknown-linux-gnu-${VER}.zip" \
  -o /tmp/bws.zip
unzip /tmp/bws.zip -d /tmp/ && install -m 0755 /tmp/bws /usr/local/bin/bws

# bws CLI server selection (matches your BWS region, e.g. US)
bws config server-base https://vault.bitwarden.com

# SSH key for GitHub clone
ssh-keygen -t ed25519 -C "ops-lxc@iedora" -f /root/.ssh/id_ed25519 -N ""
echo "→ paste the following into github.com/settings/keys:"
cat /root/.ssh/id_ed25519.pub
```

Then clone the repo and seed `.envrc`:
```bash
git clone --recurse-submodules git@github.com:eduvhc/iedora-iac.git /root/iedora-iac
cd /root/iedora-iac/iac
cp .envrc.example .envrc
${EDITOR:-vi} .envrc       # paste BW_ORGANIZATION_ID; BW_ACCESS_TOKEN comes from /root/.bws-token
echo "<BW_ACCESS_TOKEN>" > /root/.bws-token && chmod 600 /root/.bws-token
source .envrc
```

## Step 1 — First `tofu apply` (tunnel + DNS only)

Initially the iac stack only has the Cloudflare tunnel and DNS records. The
Coolify provisioning runs in a later step.

```bash
cd /root/iedora-iac/iac
tofu init
tofu plan
tofu apply
```

This creates:
- One CF tunnel (`coolify-iedora`)
- DNS CNAMEs for `coolify`, `auth`, `adguard`, `*` → tunnel

Save the tunnel token output for later:
```bash
tofu output -raw tunnel_token
```

## Step 2 — AdGuard LXC

```bash
# On PVE host
pct create 102 local:vztmpl/debian-13-standard_13.1-2_amd64.tar.zst \
  --hostname adguard --cores 1 --memory 512 --swap 256 \
  --rootfs local-lvm:2 \
  --net0 name=eth0,bridge=vmbr0,ip=192.168.50.30/24,gw=192.168.50.1 \
  --nameserver "1.1.1.1 9.9.9.9" \
  --unprivileged 1 --onboot 1 --start 1 \
  --ssh-public-keys /tmp/your-key.pub
pct set 102 --tags "infra;dns"
```

Add the ops LXC's pubkey to LXC 102 (so sync.sh can ssh), then on ops:
```bash
configs/adguard/scripts/sync.sh
```

This pushes `AdGuardHome.yaml` + `nftables.conf` and restarts services.
First-time bootstrap (AGH binary install) is currently done by the upstream
install.sh script run manually — to be folded into a `bootstrap.sh` later.

Lastly, point your router's DHCP option 6 (DNS server) at `192.168.50.30`.

## Step 3 — Gateway LXC (Caddy + Authelia)

```bash
pct create 103 ... --hostname gateway --net0 ...ip=192.168.50.40/24... \
  --tags "infra;sso"
```

On ops:
```bash
# Run bootstrap once on the gateway (generates Authelia internal secrets and
# OIDC RSA pair, creates systemd unit)
ssh root@192.168.50.40 'curl -fsSL https://raw.githubusercontent.com/eduvhc/iedora-iac/main/configs/authelia/scripts/bootstrap.sh | sh'

# Then push configs:
configs/authelia/scripts/sync.sh
configs/gateway/scripts/sync.sh
```

## Step 4 — Coolify LXC

```bash
pct create 200 local:vztmpl/debian-13-standard_13.1-2_amd64.tar.zst \
  --hostname coolify --cores 4 --memory 6144 --swap 1024 \
  --rootfs local-lvm:60 \
  --net0 name=eth0,bridge=vmbr0,ip=192.168.50.200/24,gw=192.168.50.1 \
  --nameserver "1.1.1.1 9.9.9.9" \
  --features nesting=1,keyctl=1 \
  --unprivileged 1 --onboot 1 --start 1 \
  --ssh-public-keys /tmp/your-key.pub
pct set 200 --tags "coolify;control-plane"
```

Seed BWS with the admin creds **before** bootstrap (they're read FROM there):
```bash
bws secret create COOLIFY_ADMIN_NAME     'Your Name'   <project>
bws secret create COOLIFY_ADMIN_EMAIL    'you@x.com'   <project>
bws secret create COOLIFY_ADMIN_PASSWORD "$(openssl rand -base64 18 | tr -d /+=)" <project>
```

Then on ops:
```bash
# Install Coolify, create the root user in the DB, mint a "Open Tofu" API
# token, save COOLIFY_API_TOKEN back into BWS.
configs/coolify/scripts/bootstrap.sh
```

Install cloudflared on the Coolify LXC with the tunnel token from Step 1:
```bash
TUNNEL_TOKEN=$(cd iac && tofu output -raw tunnel_token)
ssh root@192.168.50.200 "
  mkdir -p --mode=0755 /usr/share/keyrings
  curl -fsSL https://pkg.cloudflare.com/cloudflare-main.gpg \
    -o /usr/share/keyrings/cloudflare-main.gpg
  echo 'deb [signed-by=/usr/share/keyrings/cloudflare-main.gpg] https://pkg.cloudflare.com/cloudflared bookworm main' \
    > /etc/apt/sources.list.d/cloudflared.list
  apt update && apt install -y cloudflared
  cloudflared service install $TUNNEL_TOKEN
"
```

Now `https://coolify.iedora.com` resolves through the tunnel and shows the
login page. Sign in with the admin creds you put in BWS.

## Step 5 — Coolify runner LXC

```bash
pct create 210 local:vztmpl/debian-13-standard_13.1-2_amd64.tar.zst \
  --hostname coolify-runner-01 --cores 2 --memory 4096 --swap 1024 \
  --rootfs local-lvm:30 \
  --net0 name=eth0,bridge=vmbr0,ip=192.168.50.210/24,gw=192.168.50.1 \
  --nameserver "1.1.1.1 9.9.9.9" \
  --features nesting=1,keyctl=1 \
  --unprivileged 1 --onboot 1 --start 1 \
  --ssh-public-keys /tmp/your-key.pub
pct set 210 --tags "coolify;runtime"
```

Add the ops LXC pubkey to the runner's `authorized_keys`. Then on ops:

```bash
# Install Docker on the runner
ssh root@192.168.50.210 < configs/coolify-runner/scripts/bootstrap.sh

# Register the runner as a Coolify server: generates ED25519 keypair,
# pushes the public key to the runner, posts the private key + server to
# Coolify API.
cd iac && tofu apply
```

Coolify's async validate job marks the runner `usable=true` once Docker is
detected. At this point you can deploy apps to it via the Coolify UI or
API.

## Step 6 — Backup target

`vzdump` writes to the `backup` storage (USB SSD at `/mnt/pve/backup`). On
a fresh PVE you need to:

1. Plug a USB SSD or use a permanent disk
2. `mkfs.ext4 -L backup /dev/sdX1` (or partition it first)
3. Add to fstab using UUID with `nofail,x-systemd.device-timeout=10s,noatime`
4. `pvesm add dir backup --path /mnt/pve/backup --content backup,iso,vztmpl --is_mountpoint 1`
5. Confirm the daily `daily-all` vzdump job exists in `/etc/pve/jobs.cfg`

See `docs/inventory.md` for the current PVE storage layout.

## Recovery scenarios

**Lost the ops LXC**: recreate it with Step 0. The tofu state lives in this
repo (encrypted), so `tofu init && tofu plan` should show "No changes".

**Lost the tunnel token**: `tofu apply -replace=random_id.coolify_tunnel_secret`
forces a new tunnel secret, then reinstall cloudflared with the new token.

**Lost the Coolify API token**: just re-run `configs/coolify/scripts/bootstrap.sh`
— it'll skip user creation (idempotent) and mint a fresh token.

**Lost the Authelia age key** (only matters if migrating to SOPS in the
future — currently we use BWS): not applicable.

**Lost Bitwarden access**: 🚨 you're cooked. Recover the BWS account first
(Bitwarden's own recovery flow), then rebuild from step 0.
