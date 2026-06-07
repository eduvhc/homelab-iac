# References

Upstream source trees fetched **on demand** for grepping and reading. These
are NOT runtime dependencies — they're just source so any human or agent can
`cd references/<name>` and grep without hunting through GitHub.

Nothing in `references/<name>/` is tracked by git (see `.gitignore`); only
this README is committed.

## Fetching

```sh
tools/fetch-references.sh             # fetch all (shallow clone, ~slow first time)
tools/fetch-references.sh coolify     # fetch just one
```

The script is idempotent: it skips any reference whose directory already
exists. To refresh one, delete the directory and re-run:

```sh
rm -rf references/coolify
tools/fetch-references.sh coolify
```

## Available references

| Name | Branch | Used by |
|---|---|---|
| AdGuardHome                          | master | LXC 102 (DNS server) |
| coolify                              | v4.x   | LXC 200 (PaaS) |
| coolify-docs                         | v4.x   | LXC 200 (docs source) |
| opentofu                             | main   | LXC 101 (IaC tool) |
| cloudflared                          | master | LXC 200 (tunnel client) |
| terraform-provider-cloudflare        | main   | provider in providers.tf |
| terraform-provider-bitwarden-secrets | main   | provider in providers.tf |
| bitwarden-sdk-sm                     | main   | bws CLI in LXC 101 |
| authelia                             | master | LXC 103 |
| caddy                                | master | LXC 103 |
| navidrome                            | master | LXC 104 (music server) |
| bbolt                                | main   | AdGuard stats.db (verifying online-backup feasibility — see docs/backups.md) |
| Lidarr                               | plugins | LXC 105 (music library orchestrator — nightly branch for plugin support) |
| slskd                                | master | LXC 105 (Soulseek daemon) |
| Tubifarry                            | master | LXC 105 (Lidarr plugin: slskd indexer/downloader + YouTube fallback) |
| ytdl-sub                             | master | LXC 106 (YouTube channel/playlist subscriptions → Navidrome) |

All clones are shallow (`--depth=1`) against the listed branch.
