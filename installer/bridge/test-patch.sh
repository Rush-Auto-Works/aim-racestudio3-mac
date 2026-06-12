#!/bin/bash
# test-patch.sh — validate the ws2_32 Local-Network redirect patch is well-formed, strips at -p1
# (what build-wine-dlls.sh uses), rewrites the three socket send entry points, and adds the
# inbound reply-source rewrite. If $WINE_SRC points at an extracted wine tree it also
# dry-run-applies for real.
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PATCH="$HERE/wine-patch/ws2_32-localnet.patch"

PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); printf '  ok   %s\n' "$1"; }
bad() { FAIL=$((FAIL+1)); printf '  FAIL %s\n' "$1" >&2; }
# `--` so a pattern starting with '-' (e.g. the "--- a/" diff header) isn't parsed as options.
has() { grep -Fq -e "$1" -- "$PATCH" && ok "${2:-contains: ${1:0:40}}" || bad "missing: $1"; }

[ -f "$PATCH" ] && ok "patch exists" || { bad "patch missing"; exit 1; }

echo "== unified diff, -p1-strippable, single target =="
has '--- a/dlls/ws2_32/socket.c' "--- a/ header"
has '+++ b/dlls/ws2_32/socket.c' "+++ b/ header"
grep -q '^@@ ' "$PATCH" && ok "has hunk headers" || bad "no @@ hunks"
# only socket.c is touched
others="$(grep -E '^\+\+\+ ' "$PATCH" | grep -v 'dlls/ws2_32/socket.c' || true)"
[ -z "$others" ] && ok "only socket.c is modified" || bad "unexpected files: $others"

echo "== the redirect helper + forward decl are added =="
has 'static const struct sockaddr *aim_loopback_redirect(' "helper/decl signature"
has 'int is_dash = (b[0] == 10 && b[1] == 0 && b[2] == 0);' "10.0.0.0/24 dash-subnet test"
has 'int is_disco0 = (in->sin_addr.s_addr == 0 && in->sin_port == htons( 36002 ));' "0.0.0.0:36002 discovery case"
has 'if (tmp->sin_port == htons( 36002 )) tmp->sin_port = htons( 36003 );' "port 36002->36003 remap"
has 'd[0] = 127; d[1] = 0; d[2] = 0; d[3] = 1;' "127.0.0.1 rewrite"

echo "== inbound reply-source rewrite (relay 127.0.0.1:36003 -> dash 10.0.0.1:36002) =="
has 'rewrote reply source 127.0.0.1:36003 -> 10.0.0.1:36002' "inbound source-rewrite log"
has 'sin->sin_addr.s_addr == htonl( INADDR_LOOPBACK )' "inbound source match"

echo "== all three send entry points redirect =="
has 'addr = aim_loopback_redirect( addr, len, &aim_tmp );'      "connect() redirect"
has 'addr = aim_loopback_redirect( addr, addr_len, &aim_tmp );' "WS2_sendto() redirect"
has 'name = aim_loopback_redirect( name, namelen, &aim_tmp );'  "WSAConnect() redirect"
# added references to the helper on (+) lines: forward decl + def + 3 call sites + 1 mention in
# the inbound-rewrite comment ("mirror of aim_loopback_redirect") = 6.
n="$(grep -E '^\+' "$PATCH" | grep -c 'aim_loopback_redirect')"
[ "$n" -eq 6 ] && ok "6 added references (proto+def+3 calls+comment)" || bad "expected 6 added refs, got $n"

echo "== optional live dry-run apply (WINE_SRC) =="
if [ -n "${WINE_SRC:-}" ] && [ -f "$WINE_SRC/dlls/ws2_32/socket.c" ]; then
  ( cd "$WINE_SRC" && patch -p1 --dry-run < "$PATCH" >/dev/null ) && ok "applies -p1 to $WINE_SRC" || bad "dry-run apply failed"
else
  echo "  (skip: set WINE_SRC=<extracted wine tree> to dry-run apply; CI applies it for real)"
fi

echo "ws2-patch: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
