# References

Upstream source trees pinned as git submodules. Use these to read source
when debugging, understanding schemas, or finding undocumented APIs.

These are NOT runtime dependencies. They are documentation/source references
so any reader (human or agent) can `cd references/<name>` and grep without
hunting through GitHub.

| Submodule | Version pinned | Used by |
|---|---|---|
| AdGuardHome                          | latest master  | LXC 102 (DNS server) |
| coolify                              | latest main    | LXC 200 (PaaS) |
| opentofu                             | latest main    | LXC 101 (IaC tool) |
| cloudflared                          | latest master  | LXC 200 (tunnel client) |
| terraform-provider-cloudflare        | latest main    | provider in providers.tf |
| terraform-provider-bitwarden-secrets | latest main    | provider in providers.tf |
| bitwarden-sdk-sm                     | latest main    | bws CLI in LXC 101 |

## Cloning the repo with refs

```bash
git clone --recurse-submodules git@github.com:eduvhc/iedora-iac.git
# or after a plain clone:
git submodule update --init --recursive --depth 1
```

## Updating a reference to track upstream

```bash
cd references/<name>
git fetch --depth 1 origin <branch>
git checkout origin/<branch>
cd ../..
git add references/<name>
git commit -m "refs: bump <name> to <commit>"
```

## Pinning to a specific release tag

When we upgrade a service in production, pin the matching tag here too:
```bash
cd references/AdGuardHome
git fetch --depth 1 origin tag v0.107.55
git checkout v0.107.55
cd ../..
git add references/AdGuardHome
```
