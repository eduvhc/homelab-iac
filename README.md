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
iac/stacks/infra/          OpenTofu stack: PVE LXCs (bpg) + CF tunnel + DNS
iac/stacks/platform/       OpenTofu stack: Coolify-side API objects (runners, keys).
                           Reads infra outputs via terraform_remote_state.
configs/<svc>/             Config files for each service LXC
configs/<svc>/scripts/     bootstrap.sh (one-time setup) + sync.sh (push config + reload)
tools/                     Operator scripts (seed-bws, rebuild, drift-check)
docs/                      How-to docs (setup-from-scratch, inventory, 3-node-plan)
references/                Upstream source as shallow git submodules (for grep + reading)
```

The split is by **dependency boundary**: `infra` has no application-layer
dependencies and can apply against a clean PVE; `platform` needs Coolify
already running with an API token in BWS. This lets each stack be applied
without `-target=` flags.

## Quickstart

**To rebuild from a clean PVE**: follow [`docs/setup-from-scratch.md`](docs/setup-from-scratch.md).
The from-zero flow boils down to:

```bash
# On ops LXC, after cloning the repo
tools/seed-bws.sh      # interactive — populates 7 BWS secrets (idempotent)
tools/rebuild.sh       # one-shot orchestrator: infra → bootstraps → cloudflared → platform
```

After the first rebuild, install daily drift detection (cron + ntfy.sh push):
```bash
tools/install-drift-cron.sh
```

**To make changes**:

| What you want to do | Where you edit | What you run |
|---|---|---|
| Add/change LXC sizing or a new LXC | `iac/stacks/infra/locals.tf` | `cd iac/stacks/infra && tofu apply` |
| Cloudflare DNS or tunnel ingress route | `iac/stacks/infra/tunnel.tf` | `cd iac/stacks/infra && tofu apply` |
| Add a Coolify runner server | `iac/stacks/platform/runner.tf` | `cd iac/stacks/platform && tofu apply` |
| Edit AdGuard rewrites/filters | `configs/adguard/AdGuardHome.yaml` | `configs/adguard/scripts/sync.sh` |
| Add an Authelia OIDC client | `configs/authelia/configuration.yml` | `configs/authelia/scripts/sync.sh` |
| Add a Caddy reverse proxy entry | `configs/gateway/Caddyfile` | `configs/gateway/scripts/sync.sh` |
| Rotate the Coolify API token | (nothing in code) | `configs/coolify/scripts/bootstrap.sh` |

Both tofu stacks share `iac/.envrc` (one `source` covers both). After any of
the above: `git add … && git commit && git push`.

## Secrets

Live in **Bitwarden Secrets Manager** (project: `homelab`). The repo IaC
references them by name via the `bitwarden/bitwarden-secrets` provider; the
operational scripts read them via the `bws` CLI.

Secret names used:

| Key | Used by | Who creates it |
|---|---|---|
| `TOFU_STATE_PASSPHRASE` | `iac/.envrc` (state encryption, both stacks) | operator (one time) |
| `CLOUDFLARE_API_TOKEN` | infra stack: cloudflare provider | operator (one time) |
| `PVE_API_TOKEN` | infra stack: bpg/proxmox provider | operator (one time, via `pveum`) |
| `IEDORA_ADMIN_NAME` (shared) | `configs/coolify/scripts/bootstrap.sh` | operator (one time) |
| `IEDORA_ADMIN_EMAIL` (shared) | same | operator (one time) |
| `IEDORA_ADMIN_PASSWORD` (shared with Authelia) | same | operator (one time) |
| `COOLIFY_API_TOKEN` | platform stack: terraform_data registrations | `configs/coolify/scripts/bootstrap.sh` (rotates) |
| `NTFY_TOPIC` | `tools/drift-check.sh` push notifications | `tools/seed-bws.sh` (random) |

Nothing sensitive is committed to git. Both OpenTofu state files
(`iac/stacks/{infra,platform}/terraform.tfstate`) are committed but
PBKDF2-AES-GCM encrypted with `TOFU_STATE_PASSPHRASE`.

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
| `terraform-provider-cloudflare` | infra stack |
| `terraform-provider-bitwarden-secrets` | both stacks |
| `bitwarden-sdk-sm` | bws CLI in LXC 101 |
| `authelia` | LXC 103 |
| `caddy` | LXC 103 |

Clone with submodules:
```bash
git clone --recurse-submodules git@github.com:eduvhc/iedora-iac.git
# or if already cloned:
git submodule update --init --recursive --depth 1
```
