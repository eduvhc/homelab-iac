# homelab-iac

Single source of truth for the homelab on Proxmox VE. Agnostic of any
specific app. Apps run on top via Coolify and own their own infra (R2
buckets, env vars) in their own repos.

```
PVE host (Beelink N100 today, 3-node cluster soon)
├── LXC 101  ops              - OpenTofu + sops + git (where this repo is cloned)
├── LXC 102  adguard          - AdGuard Home (LAN DNS + split-DNS for *.<homelab_domain>)
├── LXC 103  gateway          - Caddy + Authelia (SSO for homelab admin UIs)
├── LXC 200  coolify          - Coolify control plane + cloudflared (CF tunnel)
└── LXC 210  coolify-runner-01 - Docker engine where apps deployed by Coolify run
```

Public access: `https://*.<homelab_domain>` → Cloudflare tunnel → either
the Coolify control plane (for `coolify.<homelab_domain>`), gateway/Caddy
(for protected admin UIs like `auth`, `adguard`), or Coolify's Traefik on
the runner (for deployed apps via the wildcard).

LAN access: AdGuard rewrites `*.<homelab_domain>` to internal IPs, so LAN
traffic bypasses the tunnel for latency.

## Layout

The repo is **service-centric**. Each homelab service owns its folder.
Network topology (IP allocations) is centralized. Moving a service between
PVE nodes edits 1 line in `services/<svc>/lxc.yaml`.

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
  │   └── authelia/         ← configuration.yml.tmpl + sync.sh + systemd unit
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
                            • apply.sh         - converge to desired state
                            • destroy.sh       - tear down everything
                            • seed-secrets.sh  - validate sops file + mint R2 backend (skeleton from iac/secrets.template.yaml)
                            • drift-check.sh + lib/{common,sops,cloudflare,sync,lxc-ips}.sh + …
docs/                       How-to docs
references/                 Upstream source fetched on demand
```

The IaC split is by **dependency boundary**. `infra` has no
application-layer dependencies and can apply against a clean PVE.
`platform` needs Coolify already running with an API token in
`iac/secrets.sops.yaml`.

## Quickstart

**To create from a clean PVE**: follow [`docs/setup-from-scratch.md`](docs/setup-from-scratch.md).
The from-zero flow:

```bash
# Phase −1 (on operator machine, once ever):
age-keygen -o ~/.config/sops/age/keys.txt && chmod 600 ~/.config/sops/age/keys.txt
# → back up keys.txt to your personal Bitwarden/1Password as a Secure Note
# → register the public key in .sops.yaml

# Phase 0-2 (on the ops LXC, after cloning the repo + scp'ing the age key):
tools/seed-secrets.sh                  # 1st run: writes encrypted skeleton from iac/secrets.template.yaml
sops iac/secrets.sops.yaml             # fill the REQUIRED keys (see template comments)
tools/seed-secrets.sh                  # 2nd run: validates + mints R2 backend creds
git add iac/secrets.sops.yaml && git commit && git push
tools/apply.sh         # idempotent: infra → bootstraps → cloudflared → platform → crons
```

To **tear down everything**: `tools/destroy.sh` (asks for confirmation).

Cron jobs are declared by their **owner**, in two places by convention:

- `services/<svc>/cron.yaml` for jobs that maintain a single service (e.g.
  `services/coolify/cron.yaml` rotates Coolify's API token).
- `iac/cron.yaml` for IaC-wide jobs that don't belong to a single service
  (e.g. drift detection, which spans both stacks).

`apply.sh` runs `tools/lib/assemble-crons` (Go), which merges both
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
| Add an Authelia OIDC client | `services/gateway/authelia/configuration.yml.tmpl` | `services/gateway/authelia/sync.sh` |
| Add a Caddy reverse proxy entry | `services/gateway/caddy/Caddyfile.tmpl` | `services/gateway/caddy/sync.sh` |
| Rotate the Coolify API token | (nothing in code) | `services/coolify/rotate-token.sh`, then `git commit && push` |
| Rotate any other secret | `sops iac/secrets.sops.yaml` (interactive editor) | `git commit && push` |
| Add a new operator (2nd age key) | append to `.sops.yaml` recipients | `sops updatekeys iac/secrets.sops.yaml` |

After any of the above: `git add … && git commit && git push`.

## Secrets

Two-tier model, organized by lifecycle.

- **`iac/secrets.sops.yaml`** is the single source for all homelab config.
  Genuine secrets and non-secret identifiers (account IDs, admin
  name/email, ntfy topic), encrypted with **age** via **sops**. Committed
  to git in encrypted form. Decrypted into `$KEY` env vars by
  `tools/lib/common.sh source_envrc` (auto-loaded via direnv per-stack
  `.envrc`). Edit with `sops iac/secrets.sops.yaml`. Layout reference:
  `iac/secrets.template.yaml`.
- **Coolify UI** holds env vars for apps deployed on the platform (DB
  passwords, JWT secrets, AI keys per app). Never duplicated elsewhere.

The age private key lives at `~/.config/sops/age/keys.txt` on each
operator machine (Mac + ops LXC).

> [!IMPORTANT]
> **Back up the age key immediately after generation.** Paste the contents
> of `~/.config/sops/age/keys.txt` into your personal password manager
> (Bitwarden Secure Note, 1Password, etc.). If you lose it AND every
> machine that holds it, the encrypted secrets are unrecoverable. That
> includes `TOFU_STATE_PASSPHRASE`, which means tofu state in R2 also
> becomes unreadable.

Entries in `iac/secrets.sops.yaml`, split by who owns them.

**Operator-provided.** Fill via `sops iac/secrets.sops.yaml`. The template
at `iac/secrets.template.yaml` shows the expected layout and how to
generate each value. `tools/seed-secrets.sh` validates these are present.
It never overwrites them.

| Key | Used by | How to provide |
|---|---|---|
| `CLOUDFLARE_API_TOKEN` | infra stack + R2 bootstrap | dash → API Tokens (scopes in template) |
| `PVE_ROOT_PASSWORD` | infra stack (bpg/proxmox provider) | set at PVE install |
| `HOMELAB_DOMAIN` | tofu (CF zone lookup + tunnel DNS), service config templates | the apex domain you own in Cloudflare |
| `NTFY_TOPIC` | drift-check alerts (threat model: spam only) | unguessable slug, e.g. `homelab-drift-$(openssl rand -hex 8)` |
| `HOMELAB_ADMIN_NAME` / `EMAIL` | Coolify + Authelia admin user | your identity |
| `HOMELAB_ADMIN_PASSWORD` | `services/coolify/bootstrap-user.sh` | your choice. Set once, not auto-rotated. |

**Auto-managed.** Don't hand-edit. Scripts/tofu overwrite.

| Key | Used by | Who writes it |
|---|---|---|
| `TOFU_STATE_PASSPHRASE` | tofu state encryption block (defense in depth above R2 token) | `tools/seed-secrets.sh` (random, one-time forever). Pure plumbing, never read by humans. |
| `R2_ACCOUNT_ID` | R2 S3 endpoint URL (in `AWS_ENDPOINT_URL_S3`) | `tools/seed-secrets.sh` derives it from `HOMELAB_DOMAIN` via CF zone lookup |
| `R2_ACCESS_KEY_ID` / `R2_SECRET_ACCESS_KEY` | tofu s3 backend | `tools/seed-secrets.sh` mints a scoped CF token. access_key = token.id, secret = sha256(token.value) |
| `COOLIFY_API_TOKEN` | platform stack: terraform_data registrations | `services/coolify/rotate-token.sh` (every apply, ≥25d cadence) |

Tofu state lives in **Cloudflare R2** (`homelab-iac-state` bucket, native
S3 locking via `use_lockfile`). The state objects are additionally
PBKDF2-AES-GCM encrypted by the `encryption{}` block with
`TOFU_STATE_PASSPHRASE`. Defense in depth if the R2 keys leak.
Nothing sensitive is committed to git.

## Docs

- [`docs/setup-from-scratch.md`](docs/setup-from-scratch.md) covers the full end-to-end procedure.
- [`docs/inventory.md`](docs/inventory.md) lists LXCs, IPs, tags, PVE storages.
- [`docs/3-node-plan.md`](docs/3-node-plan.md) is the migration plan for when 2 more PVE hosts arrive.

## References

Upstream source for the services this repo manages. Fetched on demand into
`references/<name>/` (git-ignored), so any human or agent can grep locally.

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
