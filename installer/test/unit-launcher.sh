#!/bin/bash
# unit-launcher.sh — make-launcher (standalone) writes correct, sandboxed launcher scripts.
_T_NAME="unit-launcher"
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SRC_DIR="$HERE/../src"
SBX="$(mktemp -d "${TMPDIR:-/tmp}/rs3launch.XXXXXX")"
trap 'rm -rf "$SBX" 2>/dev/null || true' EXIT

P=0; F=0
ok(){ P=$((P+1)); echo "  ok   $1"; }; bad(){ F=$((F+1)); echo "  FAIL $1" >&2; }

# Run make-launcher in standalone CLI mode, fully sandboxed (no real ~/Applications touched).
RS3_APP_SUPPORT="$SBX/app-support" RS3_APPS_DIR="$SBX/Applications" RS3_DATA_DIR="$SBX/Documents/AIM_SPORT" \
  bash "$SRC_DIR/installer-core.sh" make-launcher >/dev/null 2>&1

LS="$SBX/app-support/bin/launch.sh"
US="$SBX/app-support/bin/uninstall.sh"
CMD="$SBX/Applications/RaceStudio 3.command"

[ -f "$LS" ] && ok "launch.sh written" || bad "launch.sh missing"
[ -x "$LS" ] && ok "launch.sh executable" || bad "launch.sh not executable"
[ -f "$US" ] && ok "uninstall.sh written" || bad "uninstall.sh missing"
[ -f "$CMD" ] && ok ".command fallback created" || bad ".command missing"

# launch.sh must reference the sandboxed install root and the RS3 exe, and never ~/.wine
grep -q "$SBX/app-support" "$LS" && ok "launch.sh points at install root" || bad "launch.sh wrong root"
grep -q 'AiMRS3-64-ReleaseU.exe' "$LS" && ok "launch.sh runs the RS3 exe" || bad "launch.sh missing exe"
# Issue #37: without --disable-gpu-compositing the CEF web-maps track background renders white
# under Wine. Both the applet and the generated launch.sh MUST carry the flag on the actual launch
# command line (same line as the exe) — assert each separately so they can't drift apart.
grep -qE 'AiMRS3-64-ReleaseU\.exe.*--disable-gpu-compositing' "$LS" \
  && ok "launch.sh disables GPU compositing (web maps)" || bad "launch.sh missing --disable-gpu-compositing"
grep -qE 'AiMRS3-64-ReleaseU\.exe.*--disable-gpu-compositing' "$SRC_DIR/rs3-engine.sh" \
  && ok "engine helper disables GPU compositing (web maps)" || bad "engine helper missing --disable-gpu-compositing"

# macOS 27: the applet must NOT start Wine as its own child. LaunchServices counts Wine's hidden
# processes as the applet's subordinates and, when the applet quits, kills them (BTM "not allowed
# in background") -> explorer.exe dies, wineserver with it, RS3 freezes. The applet hands off to the
# nested helper app via `open`, so Wine gets its own LaunchServices app and coalition.
AS="$SRC_DIR/RaceStudio3.applescript"
grep -qF '/usr/bin/open ' "$AS" && grep -qF 'Contents/Helpers/RaceStudio 3.app' "$AS" \
  && ok "applet launches RS3 via open on the helper app" || bad "applet does not open the helper app"
! grep -qE 'nohup .*wine|nohup arch' "$AS" \
  && ok "applet never runs wine as its own child" || bad "applet still nohups wine"

# The helper ships LSUIElement: it execs Wine immediately and has no UI of its own. Without it
# the helper owns LaunchServices' foreground slot on launch and macOS shows its EMPTY app menu
# (bold "RaceStudio 3" title, nothing in the dropdown) and ⌘Q is dead — live A/B 2026-09-24.
grep -q 'LSUIElement' "$SRC_DIR/../build/build-apps.sh" \
  && ok "helper Info.plist sets LSUIElement" || bad "helper Info.plist missing LSUIElement"

# The helper's executable must compile with the CI toolchain (macos-14 runs this suite). Only the
# tagged release build compiled it before, so a Swift error surfaced at release time, not on the PR.
if command -v swiftc >/dev/null 2>&1; then
  swiftc -O -target arm64-apple-macos12.0 -o "$SBX/rs3-engine" "$SRC_DIR/rs3-engine.swift" >/dev/null 2>&1 \
    && ok "rs3-engine.swift compiles" || bad "rs3-engine.swift does not compile"
else
  echo "  skip rs3-engine compile check (no swiftc)"
fi

# Run the engine script inside a fake bundle layout with a stub `wine` that records its argv. It must
# find the OUTER app's Resources/wine and exec it (not background it) with the RS3 exe + flag.
if /usr/bin/arch -x86_64 /usr/bin/true 2>/dev/null; then
  OUTER="$SBX/Fake.app/Contents"; HRES="$OUTER/Helpers/RaceStudio 3.app/Contents/Resources"
  mkdir -p "$HRES" "$OUTER/Resources/wine/bin" "$SBX/home"
  cp "$SRC_DIR/rs3-engine.sh" "$HRES/rs3-engine.sh"
  printf '#!/bin/bash\nprintf "%%s\\n" "$WINEPREFIX" "$@" > "%s/argv"\n' "$SBX" > "$OUTER/Resources/wine/bin/wine"
  chmod +x "$OUTER/Resources/wine/bin/wine"
  LOGD="$SBX/home/Library/Application Support/RaceStudio3/logs"; mkdir -p "$LOGD"
  head -c 11000000 /dev/zero > "$LOGD/run.log"   # past the 10 MB rotation threshold
  HOME="$SBX/home" bash "$HRES/rs3-engine.sh" >/dev/null 2>&1
  [ "$(stat -f %z "$LOGD/run.log.1" 2>/dev/null || echo 0)" -eq 11000000 ] \
    && ok "engine script rotates a large run.log to run.log.1" || bad "engine script did not rotate run.log"
  [ "$(stat -f %z "$LOGD/run.log" 2>/dev/null || echo 99999999)" -lt 1000000 ] \
    && ok "engine script starts a fresh run.log" || bad "engine script kept appending to the big run.log"
  mv -f "$LOGD/run.log.1" "$SBX/old-run.log.1"
  printf 'small\n' > "$LOGD/run.log"
  HOME="$SBX/home" bash "$HRES/rs3-engine.sh" >/dev/null 2>&1
  grep -qx small "$LOGD/run.log" && [ ! -e "$LOGD/run.log.1" ] \
    && ok "engine script leaves a small run.log alone" || bad "engine script rotated a small run.log"
  [ -f "$SBX/argv" ] && ok "engine script execs the outer app's wine" || bad "engine script did not run outer wine"
  grep -qxF "$SBX/home/Library/Application Support/RaceStudio3/prefix" "$SBX/argv" 2>/dev/null \
    && ok "engine script sets WINEPREFIX" || bad "engine script WINEPREFIX wrong"
  grep -qx 'C:\\AIM_SPORT\\RaceStudio3\\64\\AiMRS3-64-ReleaseU.exe' "$SBX/argv" 2>/dev/null \
    && ok "engine script passes the RS3 exe" || bad "engine script RS3 exe wrong"
  [ -f "$SBX/home/Library/Application Support/RaceStudio3/logs/run.log" ] \
    && ok "engine script logs to run.log" || bad "engine script run.log missing"
else
  echo "  skip engine exec check (no Rosetta)"
fi
# run.log is appended forever by every launch; one +winsock debug session made it 234 MB. Both
# launch paths rotate it to run.log.1 past 10 MB.
# Run the generated rotation line itself (not a hand-written copy) against an 11 MB sandbox log.
ROTL="$(grep -F 'run.log.1' "$LS")"
[ -n "$ROTL" ] && ok "launch.sh carries a run.log rotation line" || bad "launch.sh never rotates run.log"
RROOT="$SBX/rot-root"; mkdir -p "$RROOT/logs"; head -c 11000000 /dev/zero > "$RROOT/logs/run.log"
ROOT="$RROOT" bash -c "$ROTL" 2>/dev/null
[ "$(stat -f %z "$RROOT/logs/run.log.1" 2>/dev/null || echo 0)" -eq 11000000 ] && [ ! -e "$RROOT/logs/run.log" ] \
  && ok "launch.sh rotation moves a large run.log to run.log.1" || bad "launch.sh rotation does not rotate"
printf 'small\n' > "$RROOT/logs/run.log"
ROOT="$RROOT" bash -c "$ROTL" 2>/dev/null
grep -qx small "$RROOT/logs/run.log" 2>/dev/null \
  && ok "launch.sh rotation leaves a small run.log alone" || bad "launch.sh rotation moved a small run.log"
grep -q 'WINEPREFIX=' "$LS" && ok "launch.sh exports WINEPREFIX" || bad "launch.sh no WINEPREFIX"
! grep -q '/.wine' "$LS" && ok "launch.sh never uses ~/.wine" || bad "launch.sh references ~/.wine"

# Every launch must re-drop Wine's `z: -> /` drive (issue #32). That per-launch repeat is how an
# already-installed prefix migrates without a reinstall, and it covers anything that later re-adds a
# root mapping. Assert the heredoc emitted a live `$ROOT` reference rather than expanding it at
# generation time — an expanded path would pin the launcher to the machine that built it.
grep -qF 'dosdevices/z:' "$LS" && ok "launch.sh drops the z: drive" || bad "launch.sh missing z: removal"
grep -qF 'zl="$ROOT/prefix/dosdevices/z:"' "$LS" \
  && ok "z: removal resolves \$ROOT at runtime" || bad "z: removal path expanded too early"
# Must only fire on a root mapping, matching drop_host_root_drive. Without the readlink guard the
# launcher would delete a deliberate z: that the shared function preserves — the two paths have to
# agree, since one runs at install time and the other on every launch.
grep -qF 'readlink "$zl"' "$LS" \
  && ok "launch.sh guards on readlink = /" || bad "launch.sh deletes z: unconditionally"

# make-launcher copies the bundled Import/Uninstall apps into the AiM apps dir when *_SRC is set.
IMP_SRC="$SBX/embed/Import RaceStudio 3 Data.app"; UNI_SRC="$SBX/embed/Uninstall RaceStudio 3.app"
mkdir -p "$IMP_SRC/Contents" "$UNI_SRC/Contents"
RS3_APP_SUPPORT="$SBX/app-support" RS3_APPS_DIR="$SBX/Applications" RS3_DATA_DIR="$SBX/Documents/AIM_SPORT" \
  IMPORT_APP_SRC="$IMP_SRC" UNINSTALL_APP_SRC="$UNI_SRC" \
  bash "$SRC_DIR/installer-core.sh" make-launcher >/dev/null 2>&1
[ -d "$SBX/Applications/Import RaceStudio 3 Data.app" ] && ok "Import app copied to AiM dir" || bad "Import app not copied"
[ -d "$SBX/Applications/Uninstall RaceStudio 3.app" ] && ok "Uninstall app copied to AiM dir" || bad "Uninstall app not copied"

# the real ~/Applications must NOT have been touched
[ ! -e "$HOME/Applications/RaceStudio 3.command" ] || echo "  note: pre-existing real launcher present (not created by this test)"

echo "unit-launcher: $P passed, $F failed"
[ "$F" -eq 0 ]
