#!/bin/bash
# build-apps.sh — build the single "RaceStudio 3.app" (install-on-first-run + launcher + import
# droplet), give it a Rush-branded icon, codesign (hardened runtime), notarize+staple if creds
# are present, then wrap it in a drag-to-Applications DMG with a Rush logo + arrow background.
#
# Output (installer/dist/):
#   RaceStudio 3.app      the app (drag to /Applications)
#   RaceStudio 3.dmg      the branded, drag-to-Applications disk image (what you distribute)
#
# Codesigning is unattended once the keychain is authorized (first codesign pops a one-time
# "use this key" dialog — click Always Allow, or pre-authorize with security set-key-partition-list).
# Notarization needs an app-specific password; without it the script signs + builds the DMG and
# prints the exact notarytool commands.
#
# Usage:
#   bash installer/build/build-apps.sh                  # sign + DMG; notarize if creds
#   NOTARY_PROFILE=rush-notary bash …/build-apps.sh     # also notarize + staple (app and DMG)
#   SKIP_SIGN=1 bash …/build-apps.sh                    # compile only (no sign, no DMG)
#   NO_TIMESTAMP=1 …                                    # local sign without the TSA (NOT notarizable)
#   NO_DMG=1 …                                          # skip the DMG step

set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SRC="$HERE/../src"
DIST="$HERE/../dist"
ASSETS="$HERE/assets"

IDENTITY="${CODESIGN_IDENTITY:-Developer ID Application: Samuel Reed (HYBSCYDCMB)}"
TEAMID="HYBSCYDCMB"
BUNDLE_ID="com.rushautoworks.racestudio3"
MIN_OS="12.0"
VERSION="1.0.0"

APP="$DIST/RaceStudio 3.app"
VOL="RaceStudio 3"
DMG="$DIST/RaceStudio 3.dmg"

say() { printf '\033[1m==> %s\033[0m\n' "$*"; }

# ---- 0. compile -----------------------------------------------------------------------------
say "Compiling RaceStudio3.applescript -> $APP"
rm -rf "$DIST"; mkdir -p "$DIST"
osacompile -o "$APP" "$SRC/RaceStudio3.applescript" || { echo "osacompile failed"; exit 1; }

# ---- 1. embed the tested engine -------------------------------------------------------------
say "Embedding engine"
RES="$APP/Contents/Resources"
mkdir -p "$RES/lib"
ditto "$SRC/installer-core.sh" "$RES/installer-core.sh"
ditto "$SRC/pins.env"          "$RES/pins.env"
ditto "$SRC/lib"               "$RES/lib"
chmod +x "$RES/installer-core.sh"

# ---- 1b. bundle the Wine engine INSIDE the app ----------------------------------------------
# Bundling Wine lets first launch skip the ~190 MB Wine download. Extract the bare wine/ tree,
# NOT the Gcenx "Wine Staging.app" wrapper (we only want bin/, lib/, share/).
# NOTE: bundling alone does NOT rename the menu bar — the Wine GUI process runs unbundled
# (its image is lib/wine/<arch>-unix/wine), so macOS reads its app name from the Mach-O
# __TEXT,__info_plist section embedded in that loader, which ships CFBundleName="Wine".
# We rebrand the app menu by patching that embedded plist below (step 1c).
say "Bundling Wine engine (this is the big step)"
. "$SRC/pins.env"   # WINE_PINNED_URL / SIZE / SHA256
WINE_TARBALL="${WINE_TARBALL:-/tmp/claude/wine11.tar.xz}"
if [ ! -f "$WINE_TARBALL" ]; then
  WINE_TARBALL="$DIST/wine.tar.xz"
  say "downloading pinned Wine…"
  curl -fSL --proto '=https' -o "$WINE_TARBALL" "$WINE_PINNED_URL" || { echo "wine download failed"; exit 1; }
fi
TMPW="$DIST/winetmp"; rm -rf "$TMPW"; mkdir -p "$TMPW"
tar -xJf "$WINE_TARBALL" -C "$TMPW" || { echo "wine extract failed"; exit 1; }
WBIN="$(find "$TMPW" -type f -name wine -path '*/bin/wine' | head -1)"
[ -n "$WBIN" ] || { echo "wine binary not found in tarball"; exit 1; }
WTREE="$(dirname "$(dirname "$WBIN")")"   # .../wine  (the dir containing bin/, lib/, share/)
ditto "$WTREE" "$RES/wine"
xattr -dr com.apple.quarantine "$RES/wine" 2>/dev/null || true
rm -rf "$TMPW"
# RS3 is native + CEF — it never uses .NET (Wine-Mono) or the HTML engine (Wine-Gecko), and we
# disable both via WINEDLLOVERRIDES anyway. Dropping them cuts ~290 MB from the bundle.
rm -rf "$RES/wine/share/wine/gecko" "$RES/wine/share/wine/mono" 2>/dev/null || true
[ -x "$RES/wine/bin/wine" ] && say "bundled wine: Contents/Resources/wine/bin/wine" || { echo "bundled wine missing"; exit 1; }

# ---- 1c. rebrand the Wine app menu to "RaceStudio 3" ----------------------------------------
# Patch CFBundleName in every unix loader's embedded __info_plist (Wine ships "Wine"). This is
# what the bold top-left app menu reads, since the GUI process runs unbundled. Must run BEFORE
# signing (it edits the Mach-O, invalidating any signature — the sign pass below re-signs it).
say "Rebranding Wine app menu -> RaceStudio 3"
while IFS= read -r loader; do
  python3 "$HERE/patch-wine-appname.py" "$loader" "RaceStudio 3" || { echo "appname patch failed for $loader"; exit 1; }
done < <(find "$RES/wine/lib/wine" -type f -name wine -path '*-unix/wine')

# ---- 2. icon (dark rounded square + Rush logo) ----------------------------------------------
say "Building app icon"
PYVENV="${PYVENV:-/tmp/rs3-build-venv}"
if [ ! -x "$PYVENV/bin/python" ]; then python3 -m venv "$PYVENV" && "$PYVENV/bin/python" -m pip install -q Pillow; fi
PY="$PYVENV/bin/python"
# Icon source: the RaceStudio 3 wordmark (sourced from a local RS3 install, gitignored), else the
# Rush square logo as a fallback so the build still works without it.
ICON_LOGO="$ASSETS/rs3-logo.png"; [ -f "$ICON_LOGO" ] || ICON_LOGO="$ASSETS/logo-square.png"
ICON_PNG="$DIST/icon-src.png"
"$PY" "$HERE/compose-icon.py" "$ICON_LOGO" "$ICON_PNG" || { echo "compose-icon.py failed"; exit 1; }
ICONSET="$DIST/rs3.iconset"; rm -rf "$ICONSET"; mkdir -p "$ICONSET"   # must NOT be hidden (iconutil rejects dot-dirs)
for s in 16 32 128 256 512; do
  sips -z "$s" "$s"           "$ICON_PNG" --out "$ICONSET/icon_${s}x${s}.png"      >/dev/null || { echo "sips resize ${s} failed"; exit 1; }
  sips -z $((s*2)) $((s*2))   "$ICON_PNG" --out "$ICONSET/icon_${s}x${s}@2x.png"   >/dev/null || { echo "sips resize ${s}@2x failed"; exit 1; }
done
iconutil -c icns "$ICONSET" -o "$DIST/rs3.icns" || { echo "iconutil failed"; exit 1; }
# osacompile made a DROPLET (because of `on open`), so it uses droplet.icns — overwrite BOTH.
cp "$DIST/rs3.icns" "$RES/applet.icns"
[ -f "$RES/droplet.icns" ] && cp "$DIST/rs3.icns" "$RES/droplet.icns"
rm -rf "$ICONSET" "$ICON_PNG"   # keep $DIST/rs3.icns — the Import/Uninstall applets reuse it (removed after 3b)

# ---- 3. Info.plist --------------------------------------------------------------------------
PL="$APP/Contents/Info.plist"
pset() { /usr/libexec/PlistBuddy -c "Set :$1 $2" "$PL" 2>/dev/null || /usr/libexec/PlistBuddy -c "Add :$1 $3 $2" "$PL"; }
pset CFBundleIdentifier "$BUNDLE_ID" string
pset CFBundleName "RaceStudio 3" string
pset CFBundleShortVersionString "$VERSION" string
pset LSMinimumSystemVersion "$MIN_OS" string
pset CFBundleIconFile "applet" string
# osacompile droplets set CFBundleIconName=droplet, which OVERRIDES CFBundleIconFile and forces the
# generic system droplet icon. Remove it so our applet.icns (the RS3 icon) is used.
/usr/libexec/PlistBuddy -c "Delete :CFBundleIconName" "$PL" 2>/dev/null || true

# ---- 3b. standalone Import / Uninstall apps -------------------------------------------------
# AppleScript applets the installer copies into ~/Applications/AiM on first run (via make-launcher
# reading IMPORT_APP_SRC/UNINSTALL_APP_SRC). They ship INSIDE this app at Contents/Resources/apps.
# Wine owns the macOS menu bar while RS3 runs and that menu can't host custom items, and the old
# NSStatusItem menu-bar helper proved unreliable (Bartender/Tahoe), so these standalone apps are
# the reachable Import/Uninstall surface (Finder, Spotlight, Launchpad, Dock).
say "Building Import / Uninstall apps"
APPS_EMBED="$RES/apps"; rm -rf "$APPS_EMBED"; mkdir -p "$APPS_EMBED"
IMPORT_EMBED="$APPS_EMBED/Import RaceStudio 3 Data.app"
UNINSTALL_EMBED="$APPS_EMBED/Uninstall RaceStudio 3.app"
osacompile -o "$IMPORT_EMBED"    "$SRC/import-app.applescript"    || { echo "osacompile import failed"; exit 1; }
osacompile -o "$UNINSTALL_EMBED" "$SRC/uninstall-app.applescript" || { echo "osacompile uninstall failed"; exit 1; }

# Import merges data, so it needs the engine — embed installer-core.sh + lib + pins.env (same
# layout as this app's Resources). Uninstall calls the self-contained uninstall.sh at run time, so
# it needs nothing extra.
IMP_RES="$IMPORT_EMBED/Contents/Resources"
ditto "$SRC/installer-core.sh" "$IMP_RES/installer-core.sh"
ditto "$SRC/pins.env"          "$IMP_RES/pins.env"
ditto "$SRC/lib"               "$IMP_RES/lib"
chmod +x "$IMP_RES/installer-core.sh"

# brand each applet: RS3 icon + identity/version. osacompile makes a droplet (uses droplet.icns)
# when the script has `on open`, else an applet (applet.icns) — overwrite whichever exists.
brand_applet() { # <app> <bundle-id> <name>
  local a="$1" bid="$2" nm="$3" pl="$1/Contents/Info.plist" r="$1/Contents/Resources"
  [ -f "$r/applet.icns" ]  && cp "$DIST/rs3.icns" "$r/applet.icns"
  [ -f "$r/droplet.icns" ] && cp "$DIST/rs3.icns" "$r/droplet.icns"
  /usr/libexec/PlistBuddy -c "Set :CFBundleIdentifier $bid" "$pl" 2>/dev/null || /usr/libexec/PlistBuddy -c "Add :CFBundleIdentifier string $bid" "$pl"
  /usr/libexec/PlistBuddy -c "Set :CFBundleName $nm" "$pl" 2>/dev/null || /usr/libexec/PlistBuddy -c "Add :CFBundleName string $nm" "$pl"
  /usr/libexec/PlistBuddy -c "Set :CFBundleShortVersionString $VERSION" "$pl" 2>/dev/null || true
  /usr/libexec/PlistBuddy -c "Add :LSMinimumSystemVersion string $MIN_OS" "$pl" 2>/dev/null || true
}
brand_applet "$IMPORT_EMBED"    "$BUNDLE_ID.import"    "Import RaceStudio 3 Data"
brand_applet "$UNINSTALL_EMBED" "$BUNDLE_ID.uninstall" "Uninstall RaceStudio 3"
rm -f "$DIST/rs3.icns"

if [ "${SKIP_SIGN:-0}" = 1 ]; then say "SKIP_SIGN=1 — compiled only."; exit 0; fi

# ---- 4. codesign ----------------------------------------------------------------------------
# NOTE (one-time): the first codesign with your Developer ID key pops a keychain dialog — click
# "Always Allow". Headless pre-auth: security unlock-keychain + set-key-partition-list
#   -S apple-tool:,apple:,codesign: -s -k "<pw>" ~/Library/Keychains/login.keychain-db
have_identity() { security find-identity -v -p codesigning 2>/dev/null | grep -q "$TEAMID"; }
if ! have_identity; then say "No Developer ID ($TEAMID) in keychain — compiled only in $DIST."; exit 0; fi
# Now that Wine is bundled, the app has hundreds of mach-o files -> --deep signs them all.
# Hardened runtime is OFF by default: Wine needs JIT/unsigned-memory entitlements to run under it,
# which we add in the notarization pass (HARDENED_RUNTIME=1). Timestamp only with hardened runtime
# (per-file TSA calls across all of Wine are slow + only needed for notarization).
ENT="$HERE/wine.entitlements.plist"
if [ "${HARDENED_RUNTIME:-0}" = 1 ]; then
  # Notarization-grade: hardened runtime needs EVERY Mach-O signed individually (the --deep
  # shortcut is rejected by notarytool). Sign all of Wine's binaries first, then the app bundle.
  TS="--timestamp"; [ "${NO_TIMESTAMP:-0}" = 1 ] && TS=""
  # Nested .app bundles must be signed before the outer app (the per-file Wine pass below only
  # touches $RES/wine, not Resources/apps). No special entitlements — they bundle no Mach-O.
  say "Signing the Import / Uninstall apps…"
  codesign --force --options runtime $TS --sign "$IDENTITY" "$IMPORT_EMBED"    || { echo "import codesign failed"; exit 1; }
  codesign --force --options runtime $TS --sign "$IDENTITY" "$UNINSTALL_EMBED" || { echo "uninstall codesign failed"; exit 1; }
  say "Signing nested Wine binaries individually (notarization-grade — slow)…"
  while IFS= read -r f; do
    case "$(file -b "$f" 2>/dev/null)" in
      *Mach-O*) codesign --force --options runtime $TS --entitlements "$ENT" --sign "$IDENTITY" "$f" 2>/dev/null || \
                say "  warn: could not sign $f" ;;
    esac
  done < <(find "$RES/wine" -type f)
  say "Signing the app bundle…"
  # shellcheck disable=SC2086
  codesign --force --options runtime $TS --entitlements "$ENT" --sign "$IDENTITY" "$APP" || { echo "codesign failed"; exit 1; }
else
  # Fast local signing (not notarizable): --deep, no hardened runtime so bundled Wine still runs.
  say "Codesigning (deep — Wine has many binaries, takes a minute)…"
  codesign --deep --force --sign "$IDENTITY" "$APP" || { echo "codesign failed"; exit 1; }
fi
codesign --verify --strict "$APP" && say "signature verifies"

# ---- 5. notarize + staple (if creds) --------------------------------------------------------
NOTARY_ARGS=""
if [ -n "${NOTARY_PROFILE:-}" ]; then
  NOTARY_ARGS="--keychain-profile $NOTARY_PROFILE"
elif [ -n "${NOTARY_KEY:-}" ] && [ -n "${NOTARY_KEY_ID:-}" ] && [ -n "${NOTARY_ISSUER:-}" ]; then
  # App Store Connect API key (.p8) — preferred; doesn't need account.apple.com
  NOTARY_ARGS="--key $NOTARY_KEY --key-id $NOTARY_KEY_ID --issuer $NOTARY_ISSUER"
elif [ -n "${NOTARY_APPLE_ID:-}" ] && [ -n "${NOTARY_PASSWORD:-}" ]; then
  NOTARY_ARGS="--apple-id $NOTARY_APPLE_ID --password $NOTARY_PASSWORD --team-id $TEAMID"
fi
notarize_staple() { # <path>
  [ -n "$NOTARY_ARGS" ] || return 2
  local t="$1" submitpath
  say "Notarizing $(basename "$t") (waits for Apple)…"
  # .app must be zipped for upload; .dmg/.pkg are submitted directly (zipping a DMG makes
  # notarytool try to unpack it -> "no signed executables / could not be unpacked").
  if [ "${t##*.}" = "app" ]; then submitpath="$t.notarize.zip"; ditto -c -k --keepParent "$t" "$submitpath"; else submitpath="$t"; fi
  # shellcheck disable=SC2086
  if xcrun notarytool submit "$submitpath" $NOTARY_ARGS --wait; then
    [ "${t##*.}" = "app" ] && rm -f "$submitpath"
    xcrun stapler staple "$t" && say "stapled $(basename "$t")"
  else echo "notarytool failed for $t"; [ "${t##*.}" = "app" ] && rm -f "$submitpath"; return 1; fi
}
# rc 2 = no notarytool credentials configured (fine — signed-only build); any other nonzero is
# a real upload/staple failure that must fail the build (this is the release artifact path).
notarize_staple "$APP" || { rc=$?; [ "$rc" -eq 2 ] || { echo "app notarization failed (rc=$rc)"; exit "$rc"; }; }

# ---- 6. branded drag-to-Applications DMG ----------------------------------------------------
if [ "${NO_DMG:-0}" = 1 ]; then say "NO_DMG=1 — skipping DMG."; exit 0; fi
say "Composing DMG background"
BG="$DIST/.bg.png"
"$PY" "$HERE/compose-dmg-bg.py" "$ASSETS/logo-wide-black.png" "$BG" || { echo "compose-dmg-bg.py failed"; exit 1; }

say "Staging DMG contents"
STAGE="$DIST/.dmgstage"; rm -rf "$STAGE"; mkdir -p "$STAGE/.background"
ditto "$APP" "$STAGE/RaceStudio 3.app" || { echo "staging ditto failed"; exit 1; }
ln -s /Applications "$STAGE/Applications"
cp "$BG" "$STAGE/.background/bg.png"

RW="$DIST/.rw.dmg"; rm -f "$RW" "$DMG"
# a stale mount of the same volume name makes `hdiutil create` fail "Resource busy" — detach first
hdiutil detach "/Volumes/$VOL" -force >/dev/null 2>&1 || true
hdiutil create -srcfolder "$STAGE" -volname "$VOL" -fs HFS+ -format UDRW -ov "$RW" >/dev/null || { echo "hdiutil create failed"; exit 1; }
DEV="$(hdiutil attach -readwrite -noverify -noautoopen "$RW" | grep -E '^/dev/' | head -1 | awk '{print $1}')"
MOUNT="/Volumes/$VOL"
sleep 1
# hygiene: drop volume cruft so it never shows (matters for users who enable hidden files)
rm -rf "$MOUNT/.fseventsd" "$MOUNT/.Trashes" 2>/dev/null || true

# Lay out the Finder window. NOTE: this scripts Finder and may pop a one-time macOS Automation
# permission prompt ("…wants to control Finder") — approve it. If it fails, the DMG is still
# functional (white background blends, just without fixed icon positions).
osascript <<OSA || say "Finder layout skipped (automation not permitted) — DMG still works."
tell application "Finder"
  tell disk "$VOL"
    open
    delay 1
    set current view of container window to icon view
    set toolbar visible of container window to false
    set statusbar visible of container window to false
    set the bounds of container window to {220, 140, 860, 706}
    set vo to the icon view options of container window
    set arrangement of vo to not arranged
    set icon size of vo to 128
    set text size of vo to 12
    set background picture of vo to file ".background:bg.png"
    set position of item "RaceStudio 3.app" of container window to {160, 235}
    set position of item "Applications" of container window to {480, 235}
    try
      set position of item ".background" of container window to {1100, 1100}
    end try
    update without registering applications
    delay 2
    close
    delay 1
  end tell
end tell
OSA
sync; sleep 1
hdiutil detach "$DEV" >/dev/null 2>&1 || hdiutil detach "$DEV" -force >/dev/null 2>&1 || true
say "Compressing DMG"
hdiutil convert "$RW" -format UDZO -imagekey zlib-level=9 -o "$DMG" >/dev/null
rm -f "$RW" "$BG"; rm -rf "$STAGE"

# sign + (optionally) notarize the DMG itself so it's stapled for offline Gatekeeper
codesign --force --sign "$IDENTITY" $TS "$DMG" 2>/dev/null && say "DMG signed"
notarize_staple "$DMG" || { rc=$?; [ "$rc" -eq 2 ] || { echo "DMG notarization failed (rc=$rc)"; exit "$rc"; }; }

say "Built: $DMG"
if [ -z "$NOTARY_ARGS" ]; then cat <<EOF

$(say "Signed but NOT notarized — no notarytool credential found.")
Create an app-specific password at https://appleid.apple.com, then:
  xcrun notarytool store-credentials rush-notary --apple-id "<you>" --team-id $TEAMID --password "<app-specific>"
  NOTARY_PROFILE=rush-notary bash installer/build/build-apps.sh
That notarizes + staples the app AND the DMG (no Gatekeeper prompt on download).
EOF
fi
ls -1 "$DIST"
