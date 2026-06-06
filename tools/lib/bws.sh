# shellcheck shell=sh
# Bitwarden Secrets Manager (`bws` CLI) helpers.
#
# Pre-reqs (callers set these — typically by sourcing iac/.envrc first):
#   - `bws` on PATH
#   - `jq` on PATH
#   - BWS_ACCESS_TOKEN / BW_ACCESS_TOKEN exported
#
# The full secret list is cached in $_BWS_CACHE (set by bws_refresh) so a
# script doing N lookups makes one `bws secret list` call, not N.
# Mutators (bws_create, bws_put_or_update) refresh the cache automatically.

# bws_refresh — populate the cache. Called lazily by bws_get/has/etc.
bws_refresh() {
  _BWS_CACHE=$(bws secret list --output json)
}

# bws_ensure_cache — populate cache if not yet set.
bws_ensure_cache() {
  [ -n "${_BWS_CACHE:-}" ] || bws_refresh
}

# bws_has KEY — exit 0 if a secret with that key exists, 1 otherwise.
bws_has() {
  bws_ensure_cache
  printf '%s' "$_BWS_CACHE" | jq -e --arg k "$1" 'any(.[]; .key==$k)' >/dev/null
}

# bws_get KEY — print the value of the secret (empty string if absent).
bws_get() {
  bws_ensure_cache
  printf '%s' "$_BWS_CACHE" | jq -r --arg k "$1" '.[] | select(.key==$k) | .value'
}

# bws_id KEY — print the secret's id (empty string if absent).
bws_id() {
  bws_ensure_cache
  printf '%s' "$_BWS_CACHE" | jq -r --arg k "$1" '.[] | select(.key==$k) | .id'
}

# bws_create KEY VALUE NOTE — create a new secret (errors if key exists).
# Caller is expected to check with bws_has first when relevant.
# Requires $BWS_PROJECT_ID set (typically by the caller from a known project name).
bws_create() {
  : "${BWS_PROJECT_ID:?bws_create: BWS_PROJECT_ID not set}"
  bws secret create "$1" "$2" "$BWS_PROJECT_ID" --note "$3" >/dev/null
  bws_refresh
}

# bws_put_or_update KEY VALUE NOTE — upsert.
bws_put_or_update() {
  : "${BWS_PROJECT_ID:?bws_put_or_update: BWS_PROJECT_ID not set}"
  _id=$(bws_id "$1")
  if [ -n "$_id" ] && [ "$_id" != "null" ]; then
    bws secret edit "$_id" --value "$2" >/dev/null
  else
    bws secret create "$1" "$2" "$BWS_PROJECT_ID" --note "$3" >/dev/null
  fi
  bws_refresh
}

# bws_project_id_by_name NAME — resolve a project name to its id.
bws_project_id_by_name() {
  bws project list --output json | jq -r --arg n "$1" '.[] | select(.name==$n) | .id'
}
