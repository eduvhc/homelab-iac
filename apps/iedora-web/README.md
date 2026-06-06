# apps/iedora-web

External infrastructure for the [`iedora-web`](https://github.com/eduvhc/iedora)
app deployed in Coolify. Scoped tofu stack — own state file
(`apps/iedora-web/terraform.tfstate` in the R2 backend), no coupling
with other apps or the platform stacks.

## What this manages

| Resource | Purpose |
|---|---|
| `cloudflare_r2_bucket.assets` | `iedora-assets` bucket for user uploads |
| `cloudflare_r2_bucket_cors.assets` | CORS allowing direct PUT/POST from app domains |
| `cloudflare_api_token.assets_rw` | Bucket-scoped token → S3-compat creds for the app |

## What this does NOT manage (lives in Coolify UI)

- The `iedora` project
- The `iedora-pg` Postgres resource + its 3 DBs (`core`, `menu`, `imopush`)
- The `iedora-web` Application (git repo, dockerfile, domains)
- All Coolify env vars (plain config + secrets)

The Coolify UI is the source of truth for app config + lifecycle. This
stack only provisions what lives **outside Coolify** and the app needs
to function (R2 bucket + S3 creds).

## Workflow

```bash
cd apps/iedora-web
tofu init
tofu apply

# Get the values to paste into Coolify UI → iedora-web → Environment Variables
tofu output -raw s3_endpoint           # S3_ENDPOINT
tofu output -raw s3_bucket             # S3_BUCKET
tofu output -raw s3_region             # S3_REGION (always "auto")
tofu output -raw s3_access_key_id      # S3_ACCESS_KEY
tofu output -raw s3_secret_access_key  # S3_SECRET_KEY
```

After pasting the 5 env vars in Coolify UI, redeploy the app.

## Rotating R2 credentials

```bash
cd apps/iedora-web
tofu apply -replace=cloudflare_api_token.assets_rw
# Then re-paste s3_access_key_id + s3_secret_access_key in Coolify UI.
```

The bucket itself + its contents are untouched.

## Adding a new app (template)

```bash
cp -r apps/iedora-web apps/<new-app>
# Edit apps/<new-app>/providers.tf → change backend key to apps/<new-app>/...
# Edit apps/<new-app>/main.tf      → adjust bucket name + CORS origins
# Edit apps/<new-app>/README.md    → describe the new app
tofu -chdir=apps/<new-app> init && tofu -chdir=apps/<new-app> apply
```

Each app's state is isolated. Destroying one never affects another.
