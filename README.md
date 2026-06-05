# iedora-iac

Single source of truth for the iedora.com homelab on Proxmox VE.

```
PVE host (Beelink N100 today, 3-node cluster soon)
├── LXC 101  ops              — OpenTofu + bws CLI + git (where this repo is cloned)
├── LXC 102  adguard          — AdGuard Home (LAN DNS + split-DNS for *.iedora.com)
├── LXC 103  gateway          — Caddy + Authelia (SSO for homelab admin UIs)
├── LXC 200  coolify          — Coolify control plane + cloudflared (CF tunnel)
└── LXC 210  coolify-runner-01 — Docker engine where apps deployed by Coolify run
```

Public access: `https://*.iedora.com` → Cloudflare tunnel → either Coolify
control plane (for `coolify.iedora.com`), gateway/Caddy (for protected admin
UIs like `auth`, `adguard`), or Coolify's Traefik on the runner (for deployed
apps via the wildcard).

LAN access: AdGuard rewrites `*.iedora.com` to internal IPs, so LAN traffic
bypasses the tunnel for latency.

## Layout

```
iac/                       OpenTofu stack (CF tunnel + DNS + Coolify server resource)
configs/<svc>/             Config files for each service LXC
configs/<svc>/scripts/     bootstrap.sh (one-time setup) + sync.sh (push config + reload)
docs/                      How-to docs (setup-from-scratch, inventory, 3-node-plan)
references/                Upstream source as shallow git submodules (for grep + reading)
```

## Quickstart

**To rebuild from a clean PVE**: follow [`docs/setup-from-scratch.md`](docs/setup-from-scratch.md).

**To make changes**:

| What you want to do | Where you edit | What you run |
|---|---|---|
| Add/change Cloudflare DNS or tunnel route | `iac/coolify.tf` (will be renamed `iac/tunnel.tf` again later) | `cd iac && tofu apply` |
| Add a Coolify runner server | `iac/coolify.tf` | `cd iac && tofu apply` |
| Edit AdGuard rewrites/filters | `configs/adguard/AdGuardHome.yaml` | `configs/adguard/scripts/sync.sh` |
| Add an Authelia OIDC client | `configs/authelia/configuration.yml` | `configs/authelia/scripts/sync.sh` |
| Add a Caddy reverse proxy entry | `configs/gateway/Caddyfile` | `configs/gateway/scripts/sync.sh` |
| Rotate the Coolify API token | (nothing in code) | `configs/coolify/scripts/bootstrap.sh` |

After any of these: `git add … && git commit && git push`.

## Secrets

Live in **Bitwarden Secrets Manager** (project: `homelab`). The repo IaC
references them by name via the `bitwarden/bitwarden-secrets` provider; the
operational scripts read them via the `bws` CLI.

Secret names used:

| Key | Used by | Who creates it |
|---|---|---|
| `TOFU_STATE_PASSPHRASE` | `iac/.envrc` (state encryption) | operator (one time) |
| `CLOUDFLARE_API_TOKEN` | tofu cloudflare provider | operator (one time) |
| `COOLIFY_ADMIN_NAME` | `configs/coolify/scripts/bootstrap.sh` | operator (one time) |
| `COOLIFY_ADMIN_EMAIL` | same | operator (one time) |
| `COOLIFY_ADMIN_PASSWORD` | same | operator (one time) |
| `COOLIFY_API_TOKEN` | tofu (server resource) | `configs/coolify/scripts/bootstrap.sh` (rotates) |

Nothing sensitive is committed to git. The OpenTofu state file
(`iac/terraform.tfstate`) is committed but PBKDF2-AES-GCM encrypted with
`TOFU_STATE_PASSPHRASE`.

## Docs

- [`docs/setup-from-scratch.md`](docs/setup-from-scratch.md) — full end-to-end procedure
- [`docs/inventory.md`](docs/inventory.md) — LXCs, IPs, tags, PVE storages
- [`docs/3-node-plan.md`](docs/3-node-plan.md) — migration plan for when 2 more PVE hosts arrive

## References

Upstream source pinned as shallow submodules under `references/` so any
human or agent can read source locally:

| Submodule | Used by |
|---|---|
| `AdGuardHome` | LXC 102 |
| `coolify` | LXC 200 |
| `coolify-docs` | LXC 200 (docs source) |
| `opentofu` | LXC 101 |
| `cloudflared` | LXC 200 |
| `terraform-provider-cloudflare` | provider in `iac/providers.tf` |
| `terraform-provider-bitwarden-secrets` | same |
| `bitwarden-sdk-sm` | bws CLI in LXC 101 |
| `authelia` | LXC 103 |
| `caddy` | LXC 103 |

Clone with submodules:
```bash
git clone --recurse-submodules git@github.com:eduvhc/iedora-iac.git
# or if already cloned:
git submodule update --init --recursive --depth 1
```
