#!/bin/sh
# Fetch upstream source references on demand.
#
# These are NOT runtime dependencies — just source trees so any human or
# agent can grep/read upstream locally without hunting through GitHub.
#
# Usage:
#   tools/fetch-references.sh             # fetch all
#   tools/fetch-references.sh <name>      # fetch one (e.g. coolify)
#
# Idempotent: skips any reference whose directory already exists.
# Each repo is cloned shallow (--depth=1) into references/<name>/.
# The references/<name>/ paths are git-ignored.

set -eu

case "${1:-}" in
  -h|--help) sed -n '2,/^$/p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
esac

# name<TAB>url<TAB>branch
REFS='AdGuardHome	https://github.com/AdguardTeam/AdGuardHome.git	master
opentofu	https://github.com/opentofu/opentofu.git	main
cloudflared	https://github.com/cloudflare/cloudflared.git	master
terraform-provider-cloudflare	https://github.com/cloudflare/terraform-provider-cloudflare.git	main
terraform-provider-bitwarden-secrets	https://github.com/bitwarden/terraform-provider-bitwarden-secrets.git	main
bitwarden-sdk-sm	https://github.com/bitwarden/sdk-sm.git	main
coolify	https://github.com/coollabsio/coolify.git	v4.x
authelia	https://github.com/authelia/authelia.git	master
caddy	https://github.com/caddyserver/caddy.git	master
coolify-docs	https://github.com/coollabsio/coolify-docs.git	v4.x'

# Resolve repo root relative to this script so it works from any cwd.
SCRIPT_DIR=$(CDPATH='' cd -- "$(dirname -- "$0")" && pwd)
REPO_ROOT=$(CDPATH='' cd -- "$SCRIPT_DIR/.." && pwd)
DEST_ROOT="$REPO_ROOT/references"

WANTED=${1:-}

fetch_one() {
    name=$1
    url=$2
    branch=$3
    dest="$DEST_ROOT/$name"

    if [ -d "$dest" ]; then
        printf '  skip   %s (already exists)\n' "$name"
        return 0
    fi

    printf '  clone  %s (branch=%s)\n' "$name" "$branch"
    git clone --depth=1 --branch "$branch" --single-branch "$url" "$dest" >/dev/null 2>&1
}

mkdir -p "$DEST_ROOT"

# Note: this loop runs in a subshell because of the pipe, so any vars set
# inside aren't visible after. We use the WANTED check below (grep the list)
# to validate `name` instead of carrying state out.
printf '%s\n' "$REFS" | while IFS='	' read -r name url branch; do
    [ -n "$name" ] || continue
    if [ -n "$WANTED" ] && [ "$WANTED" != "$name" ]; then
        continue
    fi
    fetch_one "$name" "$url" "$branch"
done

if [ -n "$WANTED" ]; then
    # `found` was set in a subshell (pipe), so re-check by grepping the list.
    if ! printf '%s\n' "$REFS" | cut -f1 | grep -qx "$WANTED"; then
        printf 'error: unknown reference "%s"\n' "$WANTED" >&2
        printf 'available:\n' >&2
        printf '%s\n' "$REFS" | cut -f1 | sed 's/^/  /' >&2
        exit 1
    fi
fi

printf 'done.\n'
