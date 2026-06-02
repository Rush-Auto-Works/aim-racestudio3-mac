#!/bin/bash
# build-apps.sh — compile the AppleScript front-ends into .app bundles, embed the tested engine,
# codesign with Developer ID (hardened runtime), and notarize+staple if credentials are present.
#
# Output: installer/dist/
#   Install RaceStudio 3.app    (the distributable; embeds core + the signed Launcher/Uninstaller)
#   Import RaceStudio 3 Data.app (drag-and-drop migration droplet; embeds core)
#   RaceStudio 3.app            (launcher — also embedded inside the installer)
#   Uninstall RaceStudio 3.app  (also embedded inside the installer)
#   Install RaceStudio 3.zip    (zipped installer, for distribution / notarization)
#
# Codesigning is unattended (uses the Developer ID identity in your keychain). Notarization needs
# an app-specific password; if no notarytool credential is found, the script codesigns and prints
# the exact commands to finish notarization yourself.
#
# Usage:
#   bash installer/build/build-apps.sh                 # codesign; notarize if creds available
#   NOTARY_PROFILE=rush-notary bash …/build-apps.sh    # use a stored `notarytool` keychain profile
#   SKIP_SIGN=1 bash …/build-apps.sh                   # just compile (for quick GUI iteration)

set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SRC="$HERE/../src"
DIST="$HERE/../dist"

IDENTITY="${CODESIGN_IDENTITY:-Developer ID Application: Samuel Reed (HYBSCYDCMB)}"
TEAMID="HYBSCYDCMB"
BUNDLE_BASE="com.rushautoworks.racestudio3"
MIN_OS="12.0"
VERSION="1.0.0"

INSTALL_APP="$DIST/Install RaceStudio 3.app"
LAUNCH_APP="$DIST/RaceStudio 3.app"
UNINST_APP="$DIST/Uninstall RaceStudio 3.app"
IMPORT_APP="$DIST/Import RaceStudio 3 Data.app"

say() { printf '\033[1m==> %s\033[0m\n' "$*"; }

# ---- 0. clean + compile --------------------------------------------------------------------
say "Compiling applets into $DIST"
rm -rf "$DIST"; mkdir -p "$DIST"
osacompile -o "$INSTALL_APP" "$SRC/Installer.applescript"   || { echo "osacompile Installer failed"; exit 1; }
osacompile -o "$LAUNCH_APP"  "$SRC/Launcher.applescript"    || { echo "osacompile Launcher failed"; exit 1; }
osacompile -o "$UNINST_APP"  "$SRC/Uninstaller.applescript" || { echo "osacompile Uninstaller failed"; exit 1; }
osacompile -o "$IMPORT_APP"  "$SRC/Import.applescript"      || { echo "osacompile Import failed"; exit 1; }

# ---- 1. embed the tested engine into the apps that run it ----------------------------------
embed_core() { # <app>
  local res="$1/Contents/Resources"
  mkdir -p "$res/lib"
  ditto "$SRC/installer-core.sh" "$res/installer-core.sh"
  ditto "$SRC/pins.env"          "$res/pins.env"
  ditto "$SRC/lib"               "$res/lib"
  chmod +x "$res/installer-core.sh"
}
say "Embedding engine into Installer + Import"
embed_core "$INSTALL_APP"
embed_core "$IMPORT_APP"

# ---- 2. set bundle metadata ----------------------------------------------------------------
plist() { # <app> <bundle-id-suffix> <name>
  local pl="$1/Contents/Info.plist"
  /usr/libexec/PlistBuddy -c "Set :CFBundleIdentifier $BUNDLE_BASE.$2" "$pl" 2>/dev/null \
    || /usr/libexec/PlistBuddy -c "Add :CFBundleIdentifier string $BUNDLE_BASE.$2" "$pl"
  /usr/libexec/PlistBuddy -c "Set :CFBundleName $3" "$pl" 2>/dev/null \
    || /usr/libexec/PlistBuddy -c "Add :CFBundleName string $3" "$pl"
  /usr/libexec/PlistBuddy -c "Set :CFBundleShortVersionString $VERSION" "$pl" 2>/dev/null \
    || /usr/libexec/PlistBuddy -c "Add :CFBundleShortVersionString string $VERSION" "$pl"
  /usr/libexec/PlistBuddy -c "Set :LSMinimumSystemVersion $MIN_OS" "$pl" 2>/dev/null \
    || /usr/libexec/PlistBuddy -c "Add :LSMinimumSystemVersion string $MIN_OS" "$pl"
}
plist "$INSTALL_APP" installer  "Install RaceStudio 3"
plist "$LAUNCH_APP"  launcher   "RaceStudio 3"
plist "$UNINST_APP"  uninstaller "Uninstall RaceStudio 3"
plist "$IMPORT_APP"  import     "Import RaceStudio 3 Data"

if [ "${SKIP_SIGN:-0}" = 1 ]; then say "SKIP_SIGN=1 — compiled only, not signed."; exit 0; fi

# ---- 3. codesign (hardened runtime). Sign leaves first, then embed into the Installer, then
#         sign the Installer WITHOUT --deep so the nested signatures/staples stay intact. -------
# --timestamp is REQUIRED for notarization but contacts Apple's TSA (can be slow/blocked on some
# networks). NO_TIMESTAMP=1 signs without it for fast LOCAL verification only — a no-timestamp
# build CANNOT be notarized; the real release build must run with the timestamp (default).
TS_FLAG="--timestamp"; [ "${NO_TIMESTAMP:-0}" = 1 ] && TS_FLAG=""
sign() { # <app>
  # shellcheck disable=SC2086
  codesign --force --options runtime $TS_FLAG --sign "$IDENTITY" "$1" \
    || { echo "codesign failed for $1"; exit 1; }
}
# NOTE (one-time): the FIRST codesign with your Developer ID key pops a keychain dialog
# ("codesign wants to use a key…") — click "Always Allow". To pre-authorize non-interactively
# (e.g. for CI), run once:
#   security unlock-keychain ~/Library/Keychains/login.keychain-db
#   security set-key-partition-list -S apple-tool:,apple:,codesign: -s \
#       -k "<login password>" ~/Library/Keychains/login.keychain-db
# Until authorized, codesign will BLOCK waiting for that dialog.
have_identity() { security find-identity -v -p codesigning 2>/dev/null | grep -q "$TEAMID"; }
if ! have_identity; then
  say "No Developer ID identity ($TEAMID) in keychain — skipping signing. Apps are compiled in $DIST."
  exit 0
fi

say "Codesigning leaves (Launcher, Uninstaller, Import)"
sign "$LAUNCH_APP"; sign "$UNINST_APP"; sign "$IMPORT_APP"

# ---- 4. notarize helper (only if creds available) ------------------------------------------
NOTARY_ARGS=""
if [ -n "${NOTARY_PROFILE:-}" ]; then
  NOTARY_ARGS="--keychain-profile $NOTARY_PROFILE"
elif [ -n "${NOTARY_APPLE_ID:-}" ] && [ -n "${NOTARY_PASSWORD:-}" ]; then
  NOTARY_ARGS="--apple-id $NOTARY_APPLE_ID --password $NOTARY_PASSWORD --team-id $TEAMID"
fi
notarize_staple() { # <app>
  [ -n "$NOTARY_ARGS" ] || return 2
  local app="$1" zip="$1.notarize.zip"
  say "Notarizing $(basename "$app") (this waits for Apple)…"
  ditto -c -k --keepParent "$app" "$zip"
  # shellcheck disable=SC2086
  if xcrun notarytool submit "$zip" $NOTARY_ARGS --wait; then
    xcrun stapler staple "$app" && say "stapled $(basename "$app")"
  else
    echo "notarytool failed for $app"; rm -f "$zip"; return 1
  fi
  rm -f "$zip"
}

# Staple the leaves before embedding so the copied-out launcher/uninstaller are independently valid.
LEAF_OK=1
for a in "$LAUNCH_APP" "$UNINST_APP"; do notarize_staple "$a" || LEAF_OK=0; done
if [ "$LEAF_OK" != 1 ] && [ -n "$NOTARY_ARGS" ]; then
  say "WARNING: a leaf app failed to notarize/staple — the launcher/uninstaller copied into ~/Applications may show a Gatekeeper prompt. Re-run the build to retry."
fi

# ---- 5. embed the (signed, ideally stapled) leaves into the Installer ----------------------
say "Embedding Launcher + Uninstaller into the Installer"
APPSDIR="$INSTALL_APP/Contents/Resources/apps"
mkdir -p "$APPSDIR"
ditto "$LAUNCH_APP" "$APPSDIR/RaceStudio 3.app"
ditto "$UNINST_APP" "$APPSDIR/Uninstall RaceStudio 3.app"

# Sign the Installer LAST, no --deep (seals the nested apps by their existing signatures).
say "Codesigning the Installer (sealing nested apps)"
sign "$INSTALL_APP"

# ---- 6. notarize the distributables --------------------------------------------------------
if [ -n "$NOTARY_ARGS" ]; then
  notarize_staple "$INSTALL_APP"
  notarize_staple "$IMPORT_APP"
  say "Done. Notarized + stapled apps are in $DIST."
else
  cat <<EOF

$(say "Codesigned, NOT notarized — no notarytool credential found.")
To finish (one-time): create an app-specific password at https://appleid.apple.com (Sign-In &
Security → App-Specific Passwords), then store it and notarize:

  xcrun notarytool store-credentials rush-notary \\
      --apple-id "<your Apple ID email>" --team-id $TEAMID --password "<app-specific-password>"

  NOTARY_PROFILE=rush-notary bash installer/build/build-apps.sh

That re-runs this script and notarizes + staples every .app. After stapling, the apps double-click
with no Gatekeeper prompt.
EOF
fi

# zip the installer for distribution
ditto -c -k --keepParent "$INSTALL_APP" "$DIST/Install RaceStudio 3.zip"
say "Built: $DIST"
ls -1 "$DIST"
