# lib/net.sh — downloads + string validation. HTTPS-only, size/sha-verified, atomic.
#
# Rules from the debate:
#   - HTTPS only. Reject anything else before it reaches curl.
#   - Download to *.partial; resume only if the partial is <= expected; size-(and sha-)verify;
#     then atomic mv into place. Fall back on ANY non-200 (covers GitHub 403 rate-limit), not
#     just connection failure.
#   - All scraped strings validated against strict regexes before they touch a filename/URL/argv.
#   - Array argv only; no eval, no built command strings.

https_guard() {  # <url>
  case "$1" in
    https://*) return 0 ;;
    *) ui_error "Refusing non-HTTPS URL: $1"; return 1 ;;
  esac
}

validate_version() {  # <s> : e.g. 11.9 or 3.83.20
  printf '%s' "$1" | grep -Eq '^[0-9]+(\.[0-9]+){1,3}$'
}

validate_wine_asset() {  # <s> : wine-staging-11.9-osx64.tar.xz
  printf '%s' "$1" | grep -Eq '^wine-(staging|devel|stable)-[0-9.]+-osx64\.tar\.xz$'
}

validate_rs3_asset() {  # <s> : RaceStudio3-64_38320_..._145224.exe
  printf '%s' "$1" | grep -Eq '^RaceStudio3-64_[0-9]+(_[0-9]+){3,}\.exe$'
}

# rs3_url_from_html <html> <filename> -> prints the first https href for <filename> in <html>.
# Pure (no network) so it's unit-testable. Exact-filename only, so even when the page lists
# several versions we return the SAME file the pin names — the caller re-verifies size+sha.
rs3_url_from_html() {  # <html> <filename>
  local html="$1" file="$2" esc
  validate_rs3_asset "$file" || return 1     # filename is safe to embed in the regex below
  esc="$(printf '%s' "$file" | sed 's/\./\\./g')"   # only '.' is regex-special in the asset name
  printf '%s' "$html" | grep -oE "https://[^\"' ]*${esc}" | head -1
}

# rs3_url_from_page <page_url> <filename> -> prints the page's live href for <filename>.
# The hardcoded RS3_PINNED_URL path can go stale even when the file itself is unchanged:
# AiM moves the installer between server directories without renaming it. We scrape the
# download page for the SAME filename and return its current URL.
rs3_url_from_page() {  # <page_url> <filename>
  local page="$1" file="$2" html
  validate_rs3_asset "$file" || return 1
  https_guard "$page" || return 1
  html="$(curl -fsSL --proto '=https' --max-time 60 "$page" 2>/dev/null)" || return 1
  rs3_url_from_html "$html" "$file"
}

# file_size <path> -> bytes (BSD stat)
file_size() { stat -f %z "$1" 2>/dev/null || echo 0; }

# sha256 <path> -> hex
sha256() { shasum -a 256 "$1" 2>/dev/null | cut -d' ' -f1; }

# download_verified <url> <dest> <expected_size> [expected_sha256] [timeout]
# Returns 0 on a verified file at <dest>; nonzero (and leaves no partial in place) otherwise.
download_verified() {
  local url="$1" dest="$2" want_size="$3" want_sha="${4:-}" tmo="${5:-1200}"
  https_guard "$url" || return 1
  local part="$dest.partial"

  # Already have a verified file? skip.
  if [ -f "$dest" ]; then
    if [ "$(file_size "$dest")" = "$want_size" ]; then
      if [ -z "$want_sha" ] || [ "$(sha256 "$dest")" = "$want_sha" ]; then return 0; fi
    fi
    rm -f "$dest"
  fi

  # Decide whether to resume: partial must be <= expected size, else restart clean.
  if [ -f "$part" ]; then
    local psz; psz="$(file_size "$part")"
    if [ "$psz" -gt "$want_size" ] 2>/dev/null; then rm -f "$part"; fi
  fi

  # -f: fail (nonzero) on HTTP >=400 so a 403/404 body is never saved as the file.
  # -C -: resume the partial. --max-time bounds the whole transfer.
  if ! watchdog "$tmo" curl -fSL -C - --proto '=https' --max-time "$tmo" \
        -o "$part" "$url"; then
    ui_warn "download failed or non-200 for $url"
    return 1
  fi

  # Verify size.
  if [ "$(file_size "$part")" != "$want_size" ]; then
    ui_warn "size mismatch for $url (got $(file_size "$part"), want $want_size)"
    rm -f "$part"; return 1
  fi
  # Verify sha if we have one.
  if [ -n "$want_sha" ]; then
    if [ "$(sha256 "$part")" != "$want_sha" ]; then
      ui_warn "sha256 mismatch for $url"
      rm -f "$part"; return 1
    fi
  fi
  mv -f "$part" "$dest"
}
