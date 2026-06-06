# iedora-iac

Single source of truth for the iedora.com homelab on Proxmox VE.

```
PVE host (Beelink N100 today, 3-node cluster soon)
├── LXC 101  ops              — OpenTofu + sops + git (where this repo is cloned)
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
  └── cloudflared/          virtual service (runs on 200 + 210 for HA)
      └── install.sh

iac/
  ├── stacks/
  │   ├── infra/            OpenTofu: discovers services/*/lxc.yaml +
  │   │                     services/*/tunnel-routes.yaml via fileset(),
  │   │                     creates LXCs + CF tunnel + DNS.
  │   └── platform/         OpenTofu: Coolify-side objects (runner registration)
  └── cron.yaml             IaC-wide cron jobs (drift detection)

tools/                      Operator scripts:
                            • apply.sh         — converge to desired state
                            • destroy.sh       — tear down everything
                            • seed-secrets.sh  — populate iac/secrets.sops.yaml + R2 bucket
                            • drift-check.sh + lib/{common,sops,cloudflare,sync,lxc-ips}.sh + …
docs/                       How-to docs
references/                 Upstream source fetched on demand
```

The IaC split is by **dependency boundary**: `infra` has no application-layer
dependencies and can apply against a clean PVE; `platform` needs Coolify
already running with an API token in `iac/secrets.sops.yaml`.

## Quickstart

**To create from a clean PVE**: follow [`docs/setup-from-scratch.md`](docs/setup-from-scratch.md).
The from-zero flow:

```bash
# On the ops LXC, after cloning the repo
tools/seed-secrets.sh  # interactive — populates iac/secrets.sops.yaml + R2 bucket
tools/apply.sh         # idempotent: infra → bootstraps → cloudflared → platform → crons
```

To **tear down everything**: `tools/destroy.sh` (asks for confirmation).

Cron jobs are declared by their **owner**, in two places by convention:

- `services/<svc>/cron.yaml` — jobs that maintain a single service (e.g.
  `services/coolify/cron.yaml` rotates Coolify's API token)
- `iac/cron.yaml` — IaC-wide jobs that don't belong to a single service
  (e.g. drift detection, which spans both stacks)

`apply.sh` runs `tools/lib/assemble-crons` (Go) which merges both
locations into `/etc/cron.d/iac` on the ops LXC. Each line carries a
header comment with its source file, so the operator sees who owns it.

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

Three-tier model, organized by lifecycle:

- **`iac/secrets.sops.yaml`** — genuine secrets, encrypted with **age** via
  **sops**. Committed to git in encrypted form; decrypted on every shell
  source by `iac/.envrc`. Edit with `sops iac/secrets.sops.yaml`.
- **`iac/.envrc`** — non-secret identifiers + config (account IDs, admin
  name/email, org IDs). Gitignored; `.envrc.example` is the committed
  template with placeholders.
- **Coolify UI** — env vars for apps deployed on the platform (DB
  passwords, JWT secrets, AI keys per app). Never duplicated elsewhere.

The age private key lives at `~/.config/sops/age/keys.txt` on each operator
machine (Mac + ops LXC). Back it up in a personal password manager — losing
it means the encrypted secrets can't be decrypted.

Secrets in `iac/secrets.sops.yaml`, grouped by lifecycle:

| Key | Group | Used by | Who creates it |
|---|---|---|---|
| `TOFU_STATE_PASSPHRASE` | bootstrap | `iac/.envrc` (state encryption) | `tools/seed-secrets.sh` (random; one-time forever) |
| `IEDORA_ADMIN_PASSWORD` | bootstrap | `services/coolify/bootstrap-user.sh` | `tools/seed-secrets.sh` (random; change in UI after first login) |
| `CLOUDFLARE_API_TOKEN` | reactive | infra stack (cloudflare provider) + `seed-secrets.sh` R2 bootstrap | operator pastes once; revokes + replaces freely |
| `PVE_ROOT_PASSWORD` | reactive | infra stack (bpg/proxmox provider) | operator (set at PVE install) |
| `COOLIFY_API_TOKEN` | reactive | platform stack: terraform_data registrations | `services/coolify/rotate-token.sh` (operator-driven, ≥25d cadence) |
| `R2_ACCESS_KEY_ID` / `R2_SECRET_ACCESS_KEY` | reactive | `iac/.envrc` → tofu s3 backend | `tools/seed-secrets.sh` (mints scoped CF token) |

Identifiers + non-secret config in `iac/.envrc` (committed in `.envrc.example`):

| Key | What it is |
|---|---|
| `R2_ACCOUNT_ID` | Cloudflare account ID — builds the R2 S3 endpoint |
| `IEDORA_ADMIN_NAME` | Display name for Coolify + Authelia admin user |
| `IEDORA_ADMIN_EMAIL` | Login email for Coolify + Authelia admin user |
| `NTFY_TOPIC` | ntfy.sh topic slug for drift alerts (threat model: spam only) |

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
| `sops` / `age` | secret encryption tooling on ops |
| `coolify` | LXC 200 |
| `coolify-docs` | LXC 200 (docs source) |
| `opentofu` | LXC 101 |
| `cloudflared` | LXC 200 |
| `terraform-provider-cloudflare` | infra stack |
| `authelia` | LXC 103 |
| `caddy` | LXC 103 |

Fetch them with the helper script:
```bash
tools/fetch-references.sh             # all
tools/fetch-references.sh coolify     # just one
```

See [`references/README.md`](references/README.md) for details.
