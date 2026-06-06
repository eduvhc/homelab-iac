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

The repo is **service-centric**. Each homelab service owns its folder. Network
topology (IP allocations) is centralized — moving a service between PVE nodes
edits 1 line in `services/<svc>/lxc.yaml`.

```
network/
  └── ips.yaml              Central LAN topology + service-name → IP map

services/
  ├── adguard/              LXC 102: AGH + nftables
  │   ├── lxc.yaml          ← container spec (vm_id, cores, mem, node, …)
  │   ├── *.tmpl            ← config templates
  │   ├── bootstrap.sh      ← one-time install
  │   └── sync.sh           ← render + push + reload
  ├── gateway/              LXC 103: Caddy + Authelia (two services, one host)
  │   ├── lxc.yaml
  │   ├── tunnel-routes.yaml ← CF tunnel routes served by this LXC
  │   ├── caddy/            ← Caddyfile.tmpl + sync.sh
  │   └── authelia/         ← configuration.yml + sync.sh + systemd unit
  ├── coolify/              LXC 200: Coolify control plane (+ cloudflared)
  │   ├── lxc.yaml
  │   ├── tunnel-routes.yaml
  │   └── bootstrap.sh
  ├── coolify-runner-01/    LXC 210: Docker engine (+ cloudflared replica)
  │   ├── lxc.yaml
  │   └── bootstrap.sh
  ├── cloudflared/          virtual service (runs on 200 + 210 for HA)
  │   └── install.sh
  └── ops/                  ops LXC config (not tofu-managed)
      └── iac.cron          declarative /etc/cron.d/iac

iac/stacks/
  ├── infra/                OpenTofu: discovers services/*/lxc.yaml +
  │                         services/*/tunnel-routes.yaml via fileset(),
  │                         creates LXCs + CF tunnel + DNS.
  └── platform/             OpenTofu: Coolify-side objects (runner registration)

tools/                      Operator scripts:
                            • apply.sh     — converge to desired state
                            • destroy.sh   — tear down everything
                            • seed-bws.sh  — seed BWS secrets + R2 bucket
                            • drift-check.sh + lib/lxc-ips.sh + …
docs/                       How-to docs
references/                 Upstream source fetched on demand
```

The IaC split is by **dependency boundary**: `infra` has no application-layer
dependencies and can apply against a clean PVE; `platform` needs Coolify
already running with an API token in BWS.

## Quickstart

**To create from a clean PVE**: follow [`docs/setup-from-scratch.md`](docs/setup-from-scratch.md).
The from-zero flow:

```bash
# On the ops LXC, after cloning the repo
tools/seed-bws.sh      # interactive — populates 10 BWS secrets + creates R2 bucket
tools/apply.sh         # idempotent: infra → bootstraps → cloudflared → platform → crons
```

To **tear down everything**: `tools/destroy.sh` (asks for confirmation).

Cron jobs are declared **per-service** in `services/<svc>/cron.yaml`
(currently: `services/coolify/cron.yaml` for token rotation,
`services/ops/cron.yaml` for drift detection). `apply.sh` runs
`tools/lib/assemble-crons.py` to merge them into `/etc/cron.d/iac` on the
ops LXC. Adding a new periodic task = drop a `cron.yaml` in the owning
service's folder; nothing else to wire up.

**To make changes**:

| What you want to do | Where you edit | What you run |
|---|---|---|
| Add a new LXC | `network/ips.yaml` + `services/<new>/lxc.yaml` | `tofu apply` in `iac/stacks/infra` |
| Resize/move an LXC | `services/<svc>/lxc.yaml` (`cores`, `memory_mb`, `node`, …) | `tofu apply` in `iac/stacks/infra` |
| Add a CF tunnel route | `services/<svc>/tunnel-routes.yaml` | `tofu apply` in `iac/stacks/infra` |
| Add a Coolify runner server | new `services/coolify-runner-NN/` + `iac/stacks/platform/runner.tf` | `tofu apply` in `iac/stacks/platform` |
| Edit AdGuard rewrites/filters | `services/adguard/AdGuardHome.yaml.tmpl` | `services/adguard/sync.sh` |
| Add an Authelia OIDC client | `services/gateway/authelia/configuration.yml` | `services/gateway/authelia/sync.sh` |
| Add a Caddy reverse proxy entry | `services/gateway/caddy/Caddyfile.tmpl` | `services/gateway/caddy/sync.sh` |
| Rotate the Coolify API token | (nothing in code) | `services/coolify/rotate-token.sh` |

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
| `CLOUDFLARE_API_TOKEN` | infra stack: cloudflare provider + `seed-bws.sh` R2 bootstrap | operator (one time) |
| `PVE_ROOT_PASSWORD` | infra stack: bpg/proxmox provider | operator (one time) |
| `IEDORA_ADMIN_NAME` (shared) | `services/coolify/bootstrap.sh` | operator (one time) |
| `IEDORA_ADMIN_EMAIL` (shared) | same | operator (one time) |
| `IEDORA_ADMIN_PASSWORD` (shared with Authelia) | same | operator (one time) |
| `COOLIFY_API_TOKEN` | platform stack: terraform_data registrations | `services/coolify/rotate-token.sh` (cron every 25d) |
| `NTFY_TOPIC` | `tools/drift-check.sh` push notifications | `tools/seed-bws.sh` (random) |
| `R2_ACCESS_KEY_ID` / `R2_SECRET_ACCESS_KEY` / `R2_ACCOUNT_ID` | `iac/.envrc` → tofu s3 backend (state in R2) | `tools/seed-bws.sh` (mints scoped CF token) |

Tofu state lives in **Cloudflare R2** (`iedora-iac-state` bucket, native
S3 locking via `use_lockfile`). The state objects are additionally
PBKDF2-AES-GCM encrypted by the `encryption{}` block with
`TOFU_STATE_PASSPHRASE` — defense in depth if the R2 keys leak.
Nothing sensitive is committed to git.

## Docs

- [`docs/setup-from-scratch.md`](docs/setup-from-scratch.md) — full end-to-end procedure
- [`docs/inventory.md`](docs/inventory.md) — LXCs, IPs, tags, PVE storages
- [`docs/3-node-plan.md`](docs/3-node-plan.md) — migration plan for when 2 more PVE hosts arrive

## References

Upstream source for the services this repo manages — fetched on demand into
`references/<name>/` (git-ignored) so any human or agent can grep locally:

| Name | Used by |
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

Fetch them with the helper script:
```bash
tools/fetch-references.sh             # all
tools/fetch-references.sh coolify     # just one
```

See [`references/README.md`](references/README.md) for details.
