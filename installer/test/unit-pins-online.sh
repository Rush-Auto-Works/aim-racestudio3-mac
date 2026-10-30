#!/bin/bash
# unit-pins-online.sh — NETWORK test. Verifies the pinned download URLs are actually live and the
# size the server reports matches the pin. SKIPS (exit 77) when offline, so the offline suite
# stays green in airgapped/sandboxed CI; runs for real anywhere with network.
#
# This is the regression guard for the stale-URL 404 that shipped to a customer (PR #8): the pin
# named the right file at the wrong directory, so a HEAD of RS3_PINNED_URL would have caught it.
_T_NAME="unit-pins-online"
. "$(dirname "${BASH_SOURCE[0]}")/harness.sh"

# Opt out explicitly (CI uses this to keep the PR gate deterministic; the scheduled run clears it
# so a dead/moved pin turns the daily build red).
if [ "${RS3_SKIP_ONLINE:-0}" = 1 ]; then
  echo "  (RS3_SKIP_ONLINE=1 — skipping online pin checks)"
  exit 77
fi

# Connectivity canary: no HTTP answer at all => skip, don't fail. Any HTTP status counts as online,
# so a 403 from AiM (the request shape in set_curl_opts stopped matching) fails the checks below
# instead of hiding behind a skip, which is how the 2026-10 Cloudflare block went unnoticed.
if [ "$(curl -sI -o /dev/null -w '%{http_code}' --max-time 10 "$RS3_DOWNLOAD_PAGE" 2>/dev/null)" = 000 ]; then
  echo "  (no network / AiM unreachable — skipping online pin checks)"
  exit 77
fi

# remote_size <url> -> Content-Length the server reports for a HEAD (following redirects).
# Empty if the URL is dead (curl -f makes 4xx/5xx fail), which then mismatches the pinned size.
remote_size() {
  set_curl_opts "$1"
  curl "${CURL_OPTS[@]}" -fsIL --max-time 30 "$1" 2>/dev/null | tr -d '\r' \
    | awk -F': ' 'tolower($1)=="content-length"{v=$2} END{print v}'
}

set_curl_opts "$RS3_DOWNLOAD_PAGE"
assert_true "curl \"\${CURL_OPTS[@]}\" -fsS -o /dev/null --max-time 30 \"\$RS3_DOWNLOAD_PAGE\"" \
  "AiM download page answers the WebUpdater request shape"

assert_eq "$(remote_size "$RS3_PINNED_URL")"  "$RS3_PINNED_SIZE"  "RS3_PINNED_URL live + size matches pin"
assert_eq "$(remote_size "$WINE_PINNED_URL")" "$WINE_PINNED_SIZE" "WINE_PINNED_URL live + size matches pin"

finish
