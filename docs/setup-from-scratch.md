# Setup from scratch

End-to-end procedure to rebuild the iedora homelab from a clean PVE host.

## Architecture in 30 seconds

Two OpenTofu stacks under `iac/stacks/`:

- **`infra`** — PVE LXCs (102/103/200/210), Cloudflare tunnel, DNS records.
  Pure infrastructure, no application-layer dependencies. Data-driven from
  `network/ips.yaml` + `services/<svc>/{lxc,tunnel-routes}.yaml`.
- **`platform`** — Coolify-side API objects (private keys, registered
  servers). Reads infra outputs via `terraform_remote_state`. Requires
  Coolify to be bootstrapped and `COOLIFY_API_TOKEN` to exist in
  `iac/secrets.sops.yaml`.

State lives in **Cloudflare R2** (s3 backend, native `use_lockfile`,
PBKDF2-AES-GCM encryption on top via OpenTofu's `encryption{}` block).

Secrets are encrypted with **age** via **sops** at `iac/secrets.sops.yaml`,
committed to the repo; `iac/.envrc` decrypts them on every shell source.
The age private key lives at `~/.config/sops/age/keys.txt` on operator
machines (Mac + ops LXC). Back it up.

The bootstrap between the two stacks is what installs Coolify itself and
mints the API token — done by `services/coolify/{install,bootstrap-user,
rotate-token}.sh` (idempotent).

## Prerequisites

- A PVE 9.x host with:
  - LAN `192.168.50.0/24`, gateway `.1`
  - Internet outbound
  - Repos on `pve-no-subscription`
  - SSH key auth for root (`PermitRootLogin prohibit-password`)
- An **age key pair** on the operator workstation. See **Phase −1** below
  for the canonical bootstrap. Lose this key = lose access to all
  encrypted secrets in `iac/secrets.sops.yaml`.
- A Cloudflare account with the `iedora.com` zone, and an API token with
  these scopes (you'll be prompted to paste it during `seed-secrets.sh`):
  - `Account / Cloudflare Tunnel: Edit`
  - `Account / Zero Trust: Edit`
  - `Account / Cloudflare R2: Edit`        ← state backend bucket
  - `User    / API Tokens: Edit`           ← to mint the scoped R2 token
  - `Zone    / DNS: Edit`

## Inventory snapshot

| LXC | Hostname | IP | Tags | Purpose |
|-----|----------|----|------|---------|
| 101 | ops | .101 | infra;iac | Where tofu + sops + git live; this repo is cloned here |
| 102 | adguard | .30 | infra;dns | AdGuard Home + nftables; split-DNS for `*.iedora.com` |
| 103 | gateway | .40 | infra;sso | Caddy + Authelia (SSO for admin UIs) |
| 200 | coolify | .200 | coolify;control-plane | Coolify UI + cloudflared connector |
| 210 | coolify-runner-01 | .210 | coolify;runtime | Docker engine + cloudflared connector (HA) |

LXCs 102/103/200/210 are tofu-managed (bpg/proxmox). LXC 101 is manual
because it's where tofu itself lives.

## Phase −1 — Age key on the operator machine

**Per-machine pattern**: each machine gets its own age key (not one key per
person). Eduardo with Mac + Windows + ops LXC = 3 separate keys. Losing
the laptop = revoke one recipient, no rotation across the others.

**Do this on every new machine** (once per machine):

```bash
# Generate the key pair (private key never leaves this machine)
mkdir -p ~/.config/sops/age && chmod 700 ~/.config/sops/age
age-keygen -o ~/.config/sops/age/keys.txt
chmod 600 ~/.config/sops/age/keys.txt

# Record the PUBLIC key — this is what goes into .sops.yaml
grep -oE 'age1[a-z0-9]+' ~/.config/sops/age/keys.txt
```

**For HUMAN-operated machines** (Mac, Windows, WSL): immediately back up
the private key in the operator's personal password manager (Bitwarden
Secure Note, 1Password) — see `keys.txt` content, paste verbatim. Key
loss = locked out of all encrypted secrets.

**For BOT machines** (ops LXC, CI runners): no backup needed — the key
is regenerable. If lost, generate a new one on that machine and re-onboard
via the steps below.

### Onboarding a new machine (existing operator with a working key required)

```bash
# 1. New machine: generate key (above) + send the PUBLIC key to an
#    existing operator.

# 2. Existing operator (with a working key): edit BOTH .sops.yaml files.
#    Append the new recipient under `keys:` with an anchor, then add the
#    anchor reference under each creation rule's `key_groups[0].age`.
#
#    Example: adding eduardo_windows to homelab-iac/.sops.yaml:
#      keys:
#        - &eduardo_mac      age1867...
#        - &eduardo_ops      age1gr7u...
#        - &eduardo_windows  age1<NEW>          ← add this line
#      creation_rules:
#        - path_regex: secrets\.sops\.yaml$
#          key_groups:
#            - age:
#                - *eduardo_mac
#                - *eduardo_ops
#                - *eduardo_windows             ← add this line

# 3. Re-wrap the DEK for the new recipient (run in homelab-iac and iedora):
cd ~/projects/personal/homelab-iac
sops updatekeys -y iac/secrets.sops.yaml

cd ~/projects/personal/iedora
bun prod:env:updatekeys

# 4. Commit + push BOTH repos.

# 5. New machine: git pull → sops -d <file> works immediately.
```

### Revoking a machine (lost, stolen, departed operator)

```bash
# 1. Edit BOTH .sops.yaml: remove the recipient's `keys:` line and the
#    matching `key_groups[0].age` reference.

# 2. updatekeys re-wraps the DEK without the revoked key + rotates DEK:
sops updatekeys -y iac/secrets.sops.yaml
(cd ~/projects/personal/iedora && bun prod:env:updatekeys)

# 3. Commit + push BOTH repos.

# 4. CRITICAL: rotate the underlying secrets too — CF token, PVE password,
#    Coolify token, R2 creds. updatekeys protects the file FORWARD but the
#    revoked operator may have already decrypted-and-copied old values.
```

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
apt update && apt install -y curl gnupg git jq ripgrep age python3-yaml

# OpenTofu
curl -fsSL https://packages.opentofu.org/opentofu/tofu/gpgkey | \
  gpg --dearmor -o /usr/share/keyrings/opentofu.gpg
echo "deb [signed-by=/usr/share/keyrings/opentofu.gpg] https://packages.opentofu.org/opentofu/tofu/any/ any main" \
  > /etc/apt/sources.list.d/opentofu.list
apt update && apt install -y tofu

# sops (binary release; not in Debian repos)
SOPS_VER=$(curl -fsSL https://api.github.com/repos/getsops/sops/releases/latest | jq -r .tag_name)
curl -fsSL "https://github.com/getsops/sops/releases/download/${SOPS_VER}/sops-${SOPS_VER}.linux.amd64" \
  -o /usr/local/bin/sops && chmod +x /usr/local/bin/sops

# SSH key the ops LXC uses to: (a) ssh to other LXCs from bootstrap scripts,
# (b) ssh to PVE host for the bpg provider, (c) clone the repo from GitHub.
ssh-keygen -t ed25519 -C "ops-lxc@iedora" -f /root/.ssh/id_ed25519 -N ""
echo "→ paste the following into github.com/settings/keys AND into PVE's /root/.ssh/authorized_keys:"
cat /root/.ssh/id_ed25519.pub
```

Clone the repo:

```bash
git clone git@github.com:eduvhc/homelab-iac.git /root/homelab-iac
# References (upstream source for grep/read) are NOT submodules — fetch on demand:
# /root/homelab-iac/tools/fetch-references.sh [<name>]
```

Push the age private key from the operator's machine to the ops LXC so
it can decrypt secrets too:

```bash
# On the operator workstation
ssh root@<ops-ip> 'mkdir -p ~/.config/sops/age && chmod 700 ~/.config/sops/age'
scp ~/.config/sops/age/keys.txt root@<ops-ip>:~/.config/sops/age/keys.txt
ssh root@<ops-ip> 'chmod 600 ~/.config/sops/age/keys.txt'
```

## Phase 1 — Seed encrypted secrets

```bash
/root/homelab-iac/tools/seed-secrets.sh
```

The script is idempotent and:
- creates `iac/secrets.sops.yaml` (if missing) — encrypted with the age key
  registered in `.sops.yaml`
- auto-generates `TOFU_STATE_PASSPHRASE`, `HOMELAB_ADMIN_PASSWORD`
- prompts for `CLOUDFLARE_API_TOKEN`, `PVE_ROOT_PASSWORD`
- prompts for identifiers: `R2_ACCOUNT_ID`, `HOMELAB_ADMIN_NAME`, `HOMELAB_ADMIN_EMAIL`
- creates the `homelab-iac-state` R2 bucket + a bucket-scoped R2 API token →
  saves `R2_ACCESS_KEY_ID`, `R2_SECRET_ACCESS_KEY` into the encrypted file
- generates a random `NTFY_TOPIC` (not a secret, but kept in sops as the
  single source of homelab config)
- skips any key that already exists

After this, **commit + push** `iac/secrets.sops.yaml` — the encrypted file
is the source of truth, shared across operator machines via git.

`COOLIFY_API_TOKEN` is created later, by `tools/apply.sh` (Phase 5 of the
apply orchestrator below).

## Phase 2 — Apply everything: `tools/apply.sh`

After secrets are seeded, the rebuild is a single command from the ops LXC:

```bash
cd /root/homelab-iac
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
| Add / rotate a secret | `sops iac/secrets.sops.yaml` (or `FORCE=1 services/coolify/rotate-token.sh` for Coolify) | commit + push the encrypted file |

All `sync.sh` and bootstrap scripts are idempotent (sha256 diff before
scp+restart). Re-running them when nothing changed is a no-op.

## Recovery scenarios

**Lost the ops LXC**: redo Phase 0 + clone repo + restore age key to
`~/.config/sops/age/keys.txt`. The encrypted secrets file in git decrypts
immediately; state lives in R2 so `tools/apply.sh` reconciles without
losing track of resources.

**Lost the tunnel token**: `cd iac/stacks/infra && tofu apply -replace=random_id.coolify_tunnel_secret`
forces a new tunnel secret; the next `tools/apply.sh` reinstalls
cloudflared on both connectors with the new token.

**Lost / expired Coolify API token**: `FORCE=1 services/coolify/rotate-token.sh`
mints a fresh token and writes it to `iac/secrets.sops.yaml`. Commit + push
to share with other operator machines. There is no auto-cron — the script
is operator-driven (it commits via git, which needs a human-supervised push).

**Lost the age private key**: catastrophic — without it the encrypted
secrets file is unreadable. Restore from the backup in your personal
password manager. As a last resort: re-run `tools/seed-secrets.sh` with a
fresh age key to regenerate `TOFU_STATE_PASSPHRASE` etc., then re-encrypt
all tofu state (`tofu init -migrate-state` after editing the encryption
block to use the old → new passphrase mapping).

**Corrupted R2 state**: `aws s3 cp s3://homelab-iac-state/infra/terraform.tfstate /backup/`
should be a daily cron (TODO — not yet implemented, candidate for
`iac/cron.yaml`). For now, the only safety net is OpenTofu's
encryption + R2's 24h soft-delete window.
