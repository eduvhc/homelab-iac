# tools/lib

Shared helpers sourced (`. <file>`) by scripts in `tools/` and
`services/<svc>/`. Each library has a header comment documenting its
contract — read the file for the authoritative API.

| Library | Purpose | Key functions |
|---|---|---|
| `common.sh` | Preamble + logging used by every script | `log_info`, `log_step`, `log_warn`, `log_err`, `die`, `require_cmd`, `source_envrc` + `$REPO_ROOT`, `TRACE=1`, `NO_COLOR=1` |
| `bws.sh` | Bitwarden Secrets Manager CLI helpers (cached) | `bws_has`, `bws_get`, `bws_id`, `bws_create`, `bws_put_or_update`, `bws_refresh`, `bws_project_id_by_name` |
| `cloudflare.sh` | Cloudflare API wrapper | `cf_api METHOD PATH [BODY]`, `cf_account_id_for_zone NAME` |
| `lxc-ips.sh` | LXC IPs from tofu outputs (sourced after infra apply) | exports `IP_ADGUARD`, `IP_GATEWAY`, `IP_COOLIFY`, `IP_RUNNER`, `ALL_LXC_IPS`, `LAN_CIDR`, `LAN_GATEWAY`, `COOLIFY_API_URL` |
| `sync.sh` | Idempotency helper for `services/*/sync.sh` | `needs_push LOCAL REMOTE` (sha256 diff) — pre-set `$HOST` |
| `assemble-crons/` | Go binary that emits `/etc/cron.d/iac` from `iac/cron.yaml` + `services/*/cron.yaml` | invoked by `tools/apply.sh` phase 8 |

## Sourcing conventions

Scripts under `tools/` use a relative path:
```sh
SCRIPT_DIR=$(cd "$(dirname "$0")" && pwd)
. "$SCRIPT_DIR/lib/common.sh"
. "$SCRIPT_DIR/lib/bws.sh"
```

Scripts under `services/<svc>/` go up two levels:
```sh
SCRIPT_DIR=$(cd "$(dirname "$0")" && pwd)
. "$SCRIPT_DIR/../../tools/lib/common.sh"
```

After `. common.sh`, `$REPO_ROOT` is set, so subsequent paths can be
written relative to it.

## Library files vs. scripts

By convention (Google Shell Style Guide), library files:

- have a `.sh` extension
- carry **no executable bit** (`chmod -x`)
- have **no `#!`** shebang (they're sourced, not executed)
- start with `# shellcheck shell=sh` so shellcheck picks the right dialect

Executable scripts have a `#!` line, the executable bit, and end in `.sh`.
