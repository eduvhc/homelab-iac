# shellcheck shell=sh
# Cloudflare API helper.
#
# Pre-reqs:
#   - $CF_TOKEN exported with a token scoped for whatever endpoints you call.
#   - `curl`, `jq` on PATH.
#
# Returns: API response body to stdout. Does NOT validate HTTP status —
# callers should jq the body's `.success`/`.errors` themselves.

# cf_api METHOD PATH [JSON-BODY]
#   PATH is the part after https://api.cloudflare.com/client/v4
#   (e.g. "/zones?per_page=1", "/accounts/$AID/r2/buckets").
cf_api() {
  : "${CF_TOKEN:?cf_api: CF_TOKEN not exported}"
  _m=$1; _p=$2; _b=${3:-}
  if [ -n "$_b" ]; then
    curl -sS -X "$_m" \
      -H "Authorization: Bearer $CF_TOKEN" \
      -H "Content-Type: application/json" \
      --data "$_b" \
      "https://api.cloudflare.com/client/v4$_p"
  else
    curl -sS -X "$_m" \
      -H "Authorization: Bearer $CF_TOKEN" \
      "https://api.cloudflare.com/client/v4$_p"
  fi
}

# cf_account_id_for_zone ZONE_NAME — return the account id that owns a zone.
# (Useful when you only have a Zone:Read scoped token.)
cf_account_id_for_zone() {
  cf_api GET "/zones?name=$1&per_page=1" | jq -r '.result[0].account.id // empty'
}
