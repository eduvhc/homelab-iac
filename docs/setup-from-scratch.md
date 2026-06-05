# Setup from scratch

End-to-end procedure for rebuilding the iedora homelab on a clean PVE host.

The OpenTofu config is split into two stacks (see `iac/stacks/`):

- **`infra`** — PVE LXCs (102/103/200/210), Cloudflare tunnel, DNS records.
  Pure infrastructure, no application-layer dependencies. Can be applied any
  time the PVE host is reachable.
- **`platform`** — Coolify-side API objects (private keys, registered servers).
  Reads infra outputs via `terraform_remote_state`. Requires Coolify to be
  bootstrapped and `COOLIFY_API_TOKEN` to exist in BWS.

The bootstrap step between the two stacks is what installs Coolify itself and
mints the API token — it's a script, not tofu. This split eliminates the
old `-target=` hack and keeps blast radius scoped.

## Prerequisites

- A PVE 9.x host with:
  - LAN `192.168.50.0/24`, gateway `.1`
  - Internet outbound
  - Repos on `pve-no-subscription` (not enterprise)
  - SSH key auth for root (`PermitRootLogin prohibit-password`)
- A Bitwarden Secrets Manager (BWS) workspace with a project named `homelab`
- A Cloudflare account with the `iedora.com` zone
- A BWS access token (created via the Bitwarden web UI under "Machine accounts")

Seed BWS **before** anything boots. Use `tools/seed-bws.sh` (from the ops LXC,
after the repo is cloned and `.envrc` is configured):

```bash
tools/seed-bws.sh
```

The script is idempotent and:
- auto-generates `TOFU_STATE_PASSPHRASE`, `IEDORA_ADMIN_PASSWORD`, `NTFY_TOPIC`
- prompts for `CLOUDFLARE_API_TOKEN`, `PVE_API_TOKEN`, `IEDORA_ADMIN_NAME`, `IEDORA_ADMIN_EMAIL`
- skips any secret that already exists

For the `PVE_API_TOKEN` it tells you to run on the PVE host:
```bash
pveum user token add root@pam tofu --privsep=0
```
…then paste the resulting full token (`root@pam!tofu=<uuid>`).

`COOLIFY_API_TOKEN` is created later, by `tools/rebuild.sh` (Phase 5 below).

## Inventory snapshot

| LXC | Hostname | IP | Tags | Purpose |
|-----|----------|----|------|---------|
| 101 | ops | .101 | infra;iac | Where tofu and bws CLI live, where this repo is cloned |
| 102 | adguard | .30 | infra;dns | AdGuard Home; split-DNS rewrites |
| 103 | gateway | .40 | infra;sso | Caddy + Authelia (SSO for admin UIs) |
| 200 | coolify | .200 | coolify;control-plane | Coolify UI + cloudflared (tunnel terminator) |
| 210 | coolify-runner-01 | .210 | coolify;runtime | Docker engine where deployed apps run |

LXCs 102/103/200/210 are tofu-managed (bpg/proxmox provider). LXC 101 is
manual because it's where tofu itself lives.

## Phase 0 — Bootstrap the ops LXC

```bash
# On PVE host
pct create 101 local:vztmpl/debian-13-standard_13.1-2_amd64.tar.zst \
  --hostname ops --cores 2 --memory 512 --swap 1024 \
  --rootfs local-lvm:10 \
  --net0 name=eth0,bridge=vmbr0,ip=192.168.50.101/24,gw=192.168.50.1 \
  --nameserver "1.1.1.1 9.9.9.9" \
  --unprivileged 1 --onboot 1 --start 1 \
  --tags "infra;iac" \
  --ssh-public-keys /tmp/your-mac-key.pub
```

Inside `ops`:

```bash
apt update && apt install -y curl gnupg git jq ripgrep unzip python3-yaml

# OpenTofu
curl -fsSL https://packages.opentofu.org/opentofu/tofu/gpgkey | \
  gpg --dearmor -o /usr/share/keyrings/opentofu.gpg
echo "deb [signed-by=/usr/share/keyrings/opentofu.gpg] https://packages.opentofu.org/opentofu/tofu/any/ any main" \
  > /etc/apt/sources.list.d/opentofu.list
apt update && apt install -y tofu

# bws CLI (latest stable)
LATEST=$(curl -fsSL "https://api.github.com/repos/bitwarden/sdk-sm/releases?per_page=50" | \
  jq -r '.[] | select(.tag_name | startswith("bws-v")) | .tag_name' | sort -V | tail -1)
VER=${LATEST#bws-v}
curl -fsSL "https://github.com/bitwarden/sdk-sm/releases/download/${LATEST}/bws-x86_64-unknown-linux-gnu-${VER}.zip" \
  -o /tmp/bws.zip
unzip /tmp/bws.zip -d /tmp/ && install -m 0755 /tmp/bws /usr/local/bin/bws
bws config server-base https://vault.bitwarden.com

# SSH key the ops LXC uses to: (a) ssh to other LXCs from bootstrap scripts,
# (b) ssh to PVE host for the bpg provider's file-upload operations,
# (c) clone iedora-iac from GitHub.
ssh-keygen -t ed25519 -C "ops-lxc@iedora" -f /root/.ssh/id_ed25519 -N ""
echo "→ paste the following into github.com/settings/keys AND into PVE's /root/.ssh/authorized_keys:"
cat /root/.ssh/id_ed25519.pub
```

Clone the repo and seed `.envrc`:

```bash
git clone --recurse-submodules git@github.com:eduvhc/iedora-iac.git /root/iedora-iac
cd /root/iedora-iac/iac
cp .envrc.example .envrc
# Edit .envrc → paste BW_ORGANIZATION_ID
echo "<BWS_ACCESS_TOKEN>" > /root/.bws-token && chmod 600 /root/.bws-token
```

## Phase 1-4 in one shot: `tools/rebuild.sh`

Once Phase 0 is done and BWS is seeded, the entire rebuild is a single
command from the ops LXC:

```bash
cd /root/iedora-iac
tools/rebuild.sh
```

This does Phases 1 through 4 in sequence with idempotency at each step. The
phases are documented below so you can run them individually if anything
breaks mid-flight.

## Phase 1 — Apply the infra stack

Creates 4 LXCs + CF tunnel + DNS records in one shot.

```bash
cd /root/iedora-iac/iac
source .envrc
cd stacks/infra
tofu init
tofu apply
```

Expected: ~2 min. After this:
- `192.168.50.{30,40,200,210}` answer on ICMP
- CF dashboard shows `coolify-iedora` tunnel + 4 CNAMEs
- `tofu output -raw tunnel_token` returns the connector token

## Phase 2 — Bootstrap each service LXC

Each LXC needs its application installed and configured. Bootstrap scripts
are idempotent — safe to re-run.

```bash
cd /root/iedora-iac

# Push ops pubkey to each LXC (so bootstrap.sh can ssh in)
for ip in 30 40 200 210; do
  ssh-copy-id -o StrictHostKeyChecking=accept-new root@192.168.50.$ip
done

# AdGuard: install AGH binary + nftables rules
ssh root@192.168.50.30 < configs/adguard/scripts/bootstrap.sh
configs/adguard/scripts/sync.sh

# Gateway: install Caddy + Authelia, generate Authelia internal secrets +
# OIDC RSA pair, create systemd units
ssh root@192.168.50.40 < configs/gateway/scripts/bootstrap.sh
configs/authelia/scripts/sync.sh
configs/gateway/scripts/sync.sh

# Coolify control plane: install Coolify, force-create root user via tinker,
# mint "Open Tofu" API token, save COOLIFY_API_TOKEN to BWS
configs/coolify/scripts/bootstrap.sh

# Coolify runner: install Docker
ssh root@192.168.50.210 < configs/coolify-runner/scripts/bootstrap.sh
```

After AdGuard is up, point your router's DHCP option 6 (DNS server) at
`192.168.50.30` so LAN devices use split-DNS.

## Phase 3 — Install cloudflared on the Coolify LXC

The tunnel was created in Phase 1; here we install the connector that
terminates it on the Coolify LXC.

```bash
cd /root/iedora-iac/iac
TUNNEL_TOKEN=$(cd stacks/infra && tofu output -raw tunnel_token)
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

Verify: `https://coolify.iedora.com` resolves through the tunnel and shows
the login page. Sign in with the `IEDORA_ADMIN_EMAIL` / `IEDORA_ADMIN_PASSWORD`.

## Phase 4 — Apply the platform stack

Now that Coolify is up and `COOLIFY_API_TOKEN` is in BWS, the platform
stack can register `coolify-runner-01` as a Coolify server.

```bash
cd /root/iedora-iac/iac/stacks/platform
tofu init
tofu apply
```

Expected: ~30 sec. After this:
- Coolify UI → Servers shows `coolify-runner-01` as `usable=true` once
  Coolify's async validator confirms Docker is reachable.

## Phase 4.5 — Install drift detection cron

Daily `tofu plan` check + ntfy push notification on any drift:

```bash
tools/install-drift-cron.sh
```

Subscribe to `https://ntfy.sh/<NTFY_TOPIC>` (value in BWS) in the ntfy app
or browser to receive alerts. The cron runs at 06:30 UTC daily; tail
`/var/log/iac-drift.log` to see history.

## Phase 5 — Backup target

`vzdump` writes to the `backup` storage (USB SSD at `/mnt/pve/backup`). On
a fresh PVE you need to:

1. Plug a USB SSD or use a permanent disk
2. `mkfs.ext4 -L backup /dev/sdX1` (or partition it first)
3. Add to fstab using UUID with `nofail,x-systemd.device-timeout=10s,noatime`
4. `pvesm add dir backup --path /mnt/pve/backup --content backup,iso,vztmpl --is_mountpoint 1`
5. Confirm the daily `daily-all` vzdump job exists in `/etc/pve/jobs.cfg`

See `docs/inventory.md` for the current PVE storage layout.

## Day-2 operations

| What changed | Where you edit | What you run |
|---|---|---|
| LXC sizing / new LXC | `iac/stacks/infra/locals.tf` | `cd iac/stacks/infra && tofu apply` |
| New CF tunnel hostname | `iac/stacks/infra/tunnel.tf` | `cd iac/stacks/infra && tofu apply` |
| Add Coolify runner server | `iac/stacks/platform/runner.tf` | `cd iac/stacks/platform && tofu apply` |
| AdGuard rewrites/filters | `configs/adguard/AdGuardHome.yaml` | `configs/adguard/scripts/sync.sh` |
| Authelia OIDC client | `configs/authelia/configuration.yml` | `configs/authelia/scripts/sync.sh` |
| Caddy reverse proxy entry | `configs/gateway/Caddyfile` | `configs/gateway/scripts/sync.sh` |
| Rotate Coolify API token | (nothing in code) | `configs/coolify/scripts/bootstrap.sh` |

## Recovery scenarios

**Lost the ops LXC**: redo Phase 0. State lives in git (encrypted), so after
clone + `source .envrc`, both `tofu plan` calls show "No changes".

**Lost the tunnel token**: `cd iac/stacks/infra && tofu apply -replace=random_id.coolify_tunnel_secret`
forces a new tunnel secret, then redo Phase 3 to reinstall cloudflared with
the new token.

**Lost the Coolify API token**: re-run `configs/coolify/scripts/bootstrap.sh`
— it'll skip user creation (idempotent) and mint a fresh token into BWS.
Then `cd iac/stacks/platform && tofu apply -replace=terraform_data.coolify_runner_01`
re-registers the runner with the new token.

**Lost Bitwarden access**: recover the BWS account first (Bitwarden's own
recovery flow), then rebuild from Phase 0.
