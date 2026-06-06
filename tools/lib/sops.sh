# shellcheck shell=sh
# SOPS+age helpers — replacement for the old BWS layer.
#
# Pre-reqs (typically satisfied by calling source_envrc from common.sh):
#   - `sops` on PATH (https://github.com/getsops/sops releases)
#   - `age` on PATH (apt install age)
#   - age private key at ~/.config/sops/age/keys.txt (chmod 600)
#
# The decrypted dotenv view is cached in $_SOPS_CACHE so a script doing N
# lookups makes one `sops -d` call, not N. Mutators (sops_set) refresh
# the cache automatically. The cache is in-memory only; never persisted.

# Caller may override; defaults to the canonical path inside the repo.
SOPS_FILE=${SOPS_FILE:-${REPO_ROOT:-.}/iac/secrets.sops.yaml}

# sops_refresh — populate the cache with the decrypted dotenv view.
sops_refresh() {
  _SOPS_CACHE=$(sops -d --output-type dotenv "$SOPS_FILE")
}

# sops_ensure_cache — populate cache if not yet set.
sops_ensure_cache() {
  [ -n "${_SOPS_CACHE:-}" ] || sops_refresh
}

# sops_has KEY — exit 0 if a secret with that key exists, 1 otherwise.
sops_has() {
  sops_ensure_cache
  printf '%s\n' "$_SOPS_CACHE" | grep -qE "^$1="
}

# sops_get KEY — print the value of the secret (empty string if absent).
sops_get() {
  sops_ensure_cache
  printf '%s\n' "$_SOPS_CACHE" | awk -F= -v k="$1" '$1==k {sub(/^[^=]*=/,""); print; exit}'
}

# sops_set KEY VALUE — upsert a key. Uses `sops set` for in-place encrypted
# write. Refreshes the cache; does NOT git-commit (caller's responsibility).
sops_set() {
  _k=$1; _v=$2
  # `sops set` expects a JSON value (string must be JSON-quoted).
  _json=$(printf '%s' "$_v" | jq -Rs .)
  sops set "$SOPS_FILE" "[\"$_k\"]" "$_json"
  sops_refresh
}
