# Setup from scratch

End-to-end procedure to rebuild the iedora homelab from a clean PVE host.

## Architecture in 30 seconds

Two OpenTofu stacks under `iac/stacks/`:

- **`infra`** — PVE LXCs (102/103/200/210), Cloudflare tunnel, DNS records.
  Pure infrastructure, no application-layer dependencies. Data-driven from
  `network/ips.yaml` + `services/<svc>/{lxc,tunnel-routes}.yaml`.
- **`platform`** — Coolify-side API objects (private keys, registered
  servers). Reads infra outputs via `terraform_remote_state`. Requires
  Coolify to be bootstrapped and `COOLIFY_API_TOKEN` to exist in BWS.

State lives in **Cloudflare R2** (s3 backend, native `use_lockfile`,
PBKDF2-AES-GCM encryption on top via OpenTofu's `encryption{}` block).

The bootstrap between the two stacks is what installs Coolify itself and
mints the API token — done by `services/coolify/{install,bootstrap-user,
rotate-token}.sh` (idempotent).

## Prerequisites

- A PVE 9.x host with:
  - LAN `192.168.50.0/24`, gateway `.1`
  - Internet outbound
  - Repos on `pve-no-subscription`
  - SSH key auth for root (`PermitRootLogin prohibit-password`)
- A Bitwarden Secrets Manager workspace with a project named `homelab`
- A Cloudflare account with the `iedora.com` zone, and an API token with
  these scopes (you'll be prompted to paste it during BWS seeding):
  - `Account / Cloudflare Tunnel: Edit`
  - `Account / Zero Trust: Edit`
  - `Account / Cloudflare R2: Edit`        ← state backend bucket
  - `User    / API Tokens: Edit`           ← to mint the scoped R2 token
  - `Zone    / DNS: Edit`

## Inventory snapshot

| LXC | Hostname | IP | Tags | Purpose |
|-----|----------|----|------|---------|
| 101 | ops | .101 | infra;iac | Where tofu + bws live; this repo is cloned here |
| 102 | adguard | .30 | infra;dns | AdGuard Home + nftables; split-DNS for `*.iedora.com` |
| 103 | gateway | .40 | infra;sso | Caddy + Authelia (SSO for admin UIs) |
| 200 | coolify | .200 | coolify;control-plane | Coolify UI + cloudflared connector |
| 210 | coolify-runner-01 | .210 | coolify;runtime | Docker engine + cloudflared connector (HA) |

LXCs 102/103/200/210 are tofu-managed (bpg/proxmox). LXC 101 is manual
because it's where tofu itself lives.

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
# (b) ssh to PVE host for the bpg provider, (c) clone the repo from GitHub.
ssh-keygen -t ed25519 -C "ops-lxc@iedora" -f /root/.ssh/id_ed25519 -N ""
echo "→ paste the following into github.com/settings/keys AND into PVE's /root/.ssh/authorized_keys:"
cat /root/.ssh/id_ed25519.pub
```

Clone the repo:

```bash
git clone git@github.com:eduvhc/iedora-iac.git /root/iedora-iac
# References (upstream source for grep/read) are NOT submodules — fetch on demand:
# /root/iedora-iac/tools/fetch-references.sh [<name>]
```

Bootstrap the BWS access token + `.envrc` template:

```bash
echo "<BWS_ACCESS_TOKEN>" > /root/.bws-token && chmod 600 /root/.bws-token
cp /root/iedora-iac/iac/.envrc.example /root/iedora-iac/iac/.envrc
# Edit /root/iedora-iac/iac/.envrc → set BW_ORGANIZATION_ID
```

## Phase 1 — Seed Bitwarden Secrets Manager

```bash
/root/iedora-iac/tools/seed-bws.sh
```

The script is idempotent and:
- auto-generates `TOFU_STATE_PASSPHRASE`, `IEDORA_ADMIN_PASSWORD`, `NTFY_TOPIC`
- prompts for `CLOUDFLARE_API_TOKEN`, `PVE_ROOT_PASSWORD`
- creates the `iedora-iac-state` R2 bucket + a bucket-scoped R2 API token →
  saves `R2_ACCESS_KEY_ID`, `R2_SECRET_ACCESS_KEY` to BWS
- reads `R2_ACCOUNT_ID`, `IEDORA_ADMIN_NAME`, `IEDORA_ADMIN_EMAIL`,
  `BW_ORGANIZATION_ID` from `iac/.envrc` (you set these once when copying
  from `.envrc.example`)
- skips any secret that already exists

`COOLIFY_API_TOKEN` is created later, by `tools/apply.sh` (Phase 5 of the
apply orchestrator below).

## Phase 2 — Apply everything: `tools/apply.sh`

After BWS is seeded, the rebuild is a single command from the ops LXC:

```bash
cd /root/iedora-iac
tools/apply.sh
# See `tools/apply.sh --help` for the per-phase breakdown.
```

This runs 8 idempotent phases in sequence:

1. `tofu apply` infra stack — 4 LXCs, CF tunnel, DNS records
2. Wait for LXCs to be SSH-reachable
3. Per-LXC bootstrap scripts (adguard, gateway, coolify-runner)
4. Install cloudflared connectors on coolify + runner (HA — 8 connections)
5. Coolify install + create root user + ensure fresh API token
6. `tofu apply` platform stack — register runner in Coolify
7. Trigger Coolify's Docker engine validation on the runner
8. Sync cron jobs to `/etc/cron.d/iac` (assembled from `iac/cron.yaml` +
   `services/*/cron.yaml` via `tools/lib/assemble-crons` Go binary)

Expected total: ~3-5 min on a warm PVE.

## Verification

After apply, all three public URLs should return 2xx/3xx:

```bash
for u in https://coolify.iedora.com/api/health https://auth.iedora.com https://adguard.iedora.com; do
  printf '%-45s ' "$u"; curl -sS -o /dev/null -w 'HTTP %{http_code}\n' "$u"
done
```

- coolify: `HTTP 200` (Coolify health endpoint)
- auth: `HTTP 200` (Authelia login page)
- adguard: `HTTP 302` (redirect to auth via Caddy forward_auth — correct)

In the Coolify UI → Servers, `coolify-runner-01` should show `usable=true`.

## Tear-down + clean rebuild

```bash
tools/destroy.sh                 # asks "type destroy to confirm"
AUTO_APPROVE=1 tools/destroy.sh  # scripted (no prompt)
```

After destroy, `tools/apply.sh` recreates everything against the same R2
state (which is now empty).

## Backup target (PVE host setup, not iac/)

`vzdump` writes to a `backup` storage. On fresh PVE you need to:

1. Plug a USB SSD or use a permanent disk
2. `mkfs.ext4 -L backup /dev/sdX1` (partition first if needed)
3. Add to fstab using UUID with `nofail,x-systemd.device-timeout=10s,noatime`
4. `pvesm add dir backup --path /mnt/pve/backup --content backup,iso,vztmpl --is_mountpoint 1`
5. Confirm the daily `daily-all` vzdump job exists in `/etc/pve/jobs.cfg`

See `docs/3-node-plan.md` for the longer-term backup strategy with PBS 4.2.

## Day-2 operations

| What changed | Where you edit | What you run |
|---|---|---|
| Resize / retag an LXC | `services/<svc>/lxc.yaml` | `tofu apply` in `iac/stacks/infra` |
| Move LXC to another PVE node | `services/<svc>/lxc.yaml` (`node:`) | `tofu apply` in `iac/stacks/infra` |
| Add a new LXC | `network/ips.yaml` + `services/<new>/lxc.yaml` | `tofu apply` in `iac/stacks/infra` |
| Add a CF tunnel route | `services/<svc>/tunnel-routes.yaml` | `tofu apply` in `iac/stacks/infra` |
| Add a runner | new `services/coolify-runner-NN/` + `iac/stacks/platform/runner.tf` | `tofu apply` in `iac/stacks/platform` |
| AdGuard rewrites/filters | `services/adguard/AdGuardHome.yaml.tmpl` | `services/adguard/sync.sh` |
| Authelia OIDC client | `services/gateway/authelia/configuration.yml` | `services/gateway/authelia/sync.sh` |
| Caddy reverse proxy entry | `services/gateway/caddy/Caddyfile.tmpl` | `services/gateway/caddy/sync.sh` |
| Add/edit a cron job | `services/<svc>/cron.yaml` (or `iac/cron.yaml` if IaC-wide) | `tools/apply.sh` (phase 8 reconciles) |
| Force-rotate the Coolify API token | (nothing in code) | `FORCE=1 services/coolify/rotate-token.sh` |

All `sync.sh` and bootstrap scripts are idempotent (sha256 diff before
scp+restart). Re-running them when nothing changed is a no-op.

## Recovery scenarios

**Lost the ops LXC**: redo Phase 0 + clone repo. State lives in R2, so
`tools/apply.sh` reconciles without losing track of resources. You'll
need the BWS access token to re-source the R2 credentials.

**Lost the tunnel token**: `cd iac/stacks/infra && tofu apply -replace=random_id.coolify_tunnel_secret`
forces a new tunnel secret; the next `tools/apply.sh` reinstalls
cloudflared on both connectors with the new token.

**Lost / expired Coolify API token**: `FORCE=1 services/coolify/rotate-token.sh`
mints a fresh token and saves to BWS. The 25-day cron (declared in
`services/coolify/cron.yaml`) catches the expiry automatically.

**Lost Bitwarden access**: recover the BWS account first (Bitwarden's own
recovery flow), then rebuild from Phase 0. The R2 state survives — once
BWS is back, `tofu init -migrate-state` is not needed because we never
migrate; we just resume.

**Corrupted R2 state**: `aws s3 cp s3://iedora-iac-state/infra/terraform.tfstate /backup/`
should be a daily cron (TODO — not yet implemented, candidate for
`iac/cron.yaml`). For now, the only safety net is OpenTofu's
encryption + R2's 24h soft-delete window.
