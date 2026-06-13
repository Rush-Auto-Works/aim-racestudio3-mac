#!/bin/bash
# check-rs3-update.sh — detect whether AiM has published a RaceStudio 3 newer than our pin, and
# (with --apply) rewrite installer/src/pins.env to the new version. Used by the weekly
# auto-release workflow; runs fine locally too.
#
#   check-rs3-update.sh            # report latest vs pinned; exit 0
#   check-rs3-update.sh --apply    # if newer: download installer, compute sha256/size, update pins.env
#
# Emits machine-readable lines to stdout (and to $GITHUB_OUTPUT when set):
#   updated=true|false   version=<M.mm.pp>   tag=v<M.mm.pp>   file=<name>   url=<url>
#
# Version detection: the download page lists installers named RaceStudio3-64_<vercode>_*.exe.
# <vercode> is a zero-padded MMmmpp-ish integer (e.g. 38320 -> 3.83.20). The newest release is
# simply the max <vercode>, so we don't depend on page wording/ordering. Page is static HTML.
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PINS="$HERE/../src/pins.env"
APPLY=0; [ "${1:-}" = "--apply" ] && APPLY=1

# shellcheck source=/dev/null
. "$PINS"
PAGE="$RS3_DOWNLOAD_PAGE"

emit() { printf '%s\n' "$1"; [ -n "${GITHUB_OUTPUT:-}" ] && printf '%s\n' "$1" >> "$GITHUB_OUTPUT" || true; }
die()  { echo "check-rs3-update: $1" >&2; exit 1; }

# vercode (e.g. 38320) -> dotted version (3.83.20)
vercode_to_ver() { printf '%d.%d.%d' $(( $1 / 10000 )) $(( ($1 / 100) % 100 )) $(( $1 % 100 )); }

html="$(curl -fsSL --proto '=https' "$PAGE")" || die "couldn't fetch $PAGE"

# All RaceStudio3-64_<vercode>_..._.exe URLs on the page, then pick the one with the max vercode.
best_url=""; best_code=0
while IFS= read -r url; do
  [ -n "$url" ] || continue
  code="$(printf '%s' "$url" | sed -nE 's#.*/RaceStudio3-64_([0-9]+)_[0-9]+_[0-9]+_[0-9]+_[0-9]+\.exe#\1#p')"
  [ -n "$code" ] || continue
  if [ "$code" -gt "$best_code" ] 2>/dev/null; then best_code="$code"; best_url="$url"; fi
done < <(printf '%s' "$html" | grep -oE 'https://[^"'"'"' ]*RaceStudio3-64_[0-9]+_[0-9]+_[0-9]+_[0-9]+_[0-9]+\.exe')

[ "$best_code" -gt 0 ] || die "no RaceStudio3-64 installer link found on $PAGE"

latest_ver="$(vercode_to_ver "$best_code")"
latest_file="$(basename "$best_url")"
cur_code="$(printf '%s' "$RS3_PINNED_FILE" | sed -nE 's#RaceStudio3-64_([0-9]+)_.*#\1#p')"

echo "pinned : $RS3_PINNED_VER ($RS3_PINNED_FILE)" >&2
echo "latest : $latest_ver ($latest_file)" >&2

if [ "$best_code" -le "${cur_code:-0}" ] 2>/dev/null; then
  emit "updated=false"; emit "version=$RS3_PINNED_VER"
  echo "Up to date." >&2
  exit 0
fi

echo "Newer RaceStudio 3 available: $RS3_PINNED_VER -> $latest_ver" >&2
# A new upstream version resets the downstream packaging revision to 1 → tag v<ver>-1.
emit "updated=true"; emit "version=$latest_ver"; emit "tag=v$latest_ver-1"
emit "file=$latest_file"; emit "url=$best_url"

[ "$APPLY" = 1 ] || { echo "(report only; pass --apply to update pins.env)" >&2; exit 0; }

# Download + verify the new installer, compute size + sha256.
tmp="$(mktemp -d)"; trap 'rm -rf "$tmp"' EXIT
dest="$tmp/$latest_file"
echo "downloading $best_url …" >&2
curl -fSL --proto '=https' -o "$dest" "$best_url" || die "download failed: $best_url"
[ -r "$dest" ] || die "downloaded installer not readable: $dest"

# size: BSD stat (-f, macOS) then GNU stat (-c, Linux).
size="$(stat -f %z "$dest" 2>/dev/null || stat -c %s "$dest" 2>/dev/null)" || true
[ -n "$size" ] || die "couldn't read size of $dest (no working 'stat')"

# sha256: shasum (macOS/perl) or sha256sum (Linux) — report which tool is missing.
if command -v shasum >/dev/null 2>&1; then
  sha="$(shasum -a 256 "$dest" | awk '{print $1}')"
elif command -v sha256sum >/dev/null 2>&1; then
  sha="$(sha256sum "$dest" | awk '{print $1}')"
else
  die "no sha256 tool found (need 'shasum' or 'sha256sum')"
fi
[ -n "$sha" ] || die "sha256 computation failed for $dest"

# Rewrite the five pinned fields in place (anchored, one per line).
ed_pins() { # <key> <new-value-line>
  local key="$1" line="$2"
  sed -i.bak -E "s|^${key}=.*$|${line}|" "$PINS" && rm -f "$PINS.bak"
}
ed_pins "RS3_PINNED_VER"  "RS3_PINNED_VER=\"$latest_ver\""
ed_pins "RS3_PINNED_FILE" "RS3_PINNED_FILE=\"$latest_file\""
ed_pins "RS3_PINNED_URL"  "RS3_PINNED_URL=\"$best_url\""
ed_pins "RS3_PINNED_SIZE" "RS3_PINNED_SIZE=$size"
ed_pins "RS3_PINNED_SHA256" "RS3_PINNED_SHA256=\"$sha\""
# New upstream version → reset the downstream packaging revision to 1 (matches the v<ver>-1 tag).
ed_pins "RS3_PKG_REV" "RS3_PKG_REV=\"1\""

echo "pins.env updated -> $latest_ver (size=$size sha256=$sha)" >&2
