# iedora-iac

OpenTofu IaC for iedora.com (Cloudflare Tunnel + DNS for the Coolify host).
Secrets live in **Bitwarden Secrets Manager**, project `homelab`.

## What it manages

```
coolify.iedora.com  -> CF tunnel -> http://localhost:8000  (Coolify UI)
*.iedora.com        -> CF tunnel -> http://localhost:80    (Traefik in Coolify)
```

## Docs

- [3-node migration plan](docs/3-node-plan.md) - playbook for when 2 new machines arrive
- [AdGuard Home config](configs/adguard/AdGuardHome.yaml) - split-DNS rewrites for *.iedora.com


State and plan are AES-GCM encrypted with a PBKDF2-derived key.
The encrypted terraform.tfstate IS committed to this public repo.
Recovery requires the BWS access token + state passphrase (also in BWS).

## Required BWS secrets (project: homelab)

> The CF account_id and zone_id are looked up at plan-time via the
> `cloudflare_zone` data source (filtered by domain). The API token must be
> scoped to a specific account + zone for the lookup to be deterministic.


| Key                       | Content                                          |
|---------------------------|--------------------------------------------------|
| CLOUDFLARE_API_TOKEN      | Cloudflare API token (Tunnel:Edit + Zero Trust:Edit + DNS:Edit, scoped to account + iedora.com zone)|
| TOFU_STATE_PASSPHRASE     | Passphrase for state encryption (>=16 chars)     |

The machine account must have read access to the `homelab` project.

## Editing secrets

In the Bitwarden web UI: Secrets Manager -> Projects -> homelab -> click the
secret -> edit value -> save. Next `tofu apply` picks up the new value
automatically.

## One-time setup on a fresh machine

```bash
# Install OpenTofu, bws CLI, git, jq.

# Write the machine-account access token (sensitive, 0600):
echo "<BW_ACCESS_TOKEN>" > /root/.bws-token
chmod 600 /root/.bws-token

# Clone repo and bootstrap:
git clone <repo-url> /root/iedora-iac
cd /root/iedora-iac
cp .envrc.example .envrc
${EDITOR:-vi} .envrc      # set BW_ORGANIZATION_ID
source .envrc

tofu init
tofu plan
tofu apply
```

## Day-to-day

```bash
cd /root/iedora-iac
source .envrc
tofu plan
tofu apply
git add . && git commit -m "..." && git push
```

## Get the tunnel token (after first apply)

```bash
TUNNEL_TOKEN=$(tofu output -raw tunnel_token)
ssh root@192.168.50.200 "cloudflared service install $TUNNEL_TOKEN"
ssh root@192.168.50.200 "systemctl status cloudflared --no-pager | head -5"
```

## Disaster recovery

1. Fresh machine with OpenTofu + bws + git + jq.
2. Create or reuse a BWS machine account, generate access token.
3. `echo $TOKEN > /root/.bws-token && chmod 600 /root/.bws-token`.
4. `git clone` + `cp .envrc.example .envrc` + set BW_ORGANIZATION_ID.
5. `source .envrc && tofu init && tofu plan` -> "No changes" if state is current.

If the BWS access token + state passphrase are both lost, recover by:
- Generating new state passphrase in BWS.
- `rm -f terraform.tfstate*` and `tofu import` each existing CF resource by ID.

## Files

| File              | Purpose                                            |
|-------------------|----------------------------------------------------|
| providers.tf      | Required providers + state encryption block      |
| variables.tf      | tf_state_passphrase + domain + bws_keys mapping  |
| bws.tf            | BWS data sources (list secrets, fetch by key)    |
| coolify.tf        | Tunnel + ingress + DNS records                   |
| outputs.tf        | tunnel_id + tunnel_token                         |
| .envrc.example    | Template for env vars (copy to .envrc)           |
| .gitignore        | Hides .terraform/, .envrc, terraform.tfvars     |
| terraform.tfstate | ENCRYPTED, committed                            |
