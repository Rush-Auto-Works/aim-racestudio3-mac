#!/usr/bin/env bash
# Create a CrossOver bottle and run the RaceStudio 3 installer (current CrossOver, v24+).
# On a modern CrossOver this needs no .NET/shim/hacks — the official installer just works.
#
# Usage: ./install-crossover.sh [/path/to/RaceStudio3-64_xxx.exe] [bottle-name]
set -euo pipefail

INSTALLER="${1:-}"; BOTTLE="${2:-RaceStudio3}"
CX="/Applications/CrossOver.app/Contents/SharedSupport/CrossOver"
[ -d "$CX" ] || { echo "CrossOver not found. Install it from https://www.codeweavers.com/crossover" >&2; exit 1; }

VER="$(defaults read /Applications/CrossOver.app/Contents/Info.plist CFBundleShortVersionString 2>/dev/null || echo '?')"
MAJOR="${VER%%.*}"
echo "CrossOver version: $VER"
if [ "${MAJOR:-0}" -lt 24 ] 2>/dev/null; then
  echo "WARNING: CrossOver $VER is old. The installer will likely crash (0xe06d7363) and the"
  echo "UI will render garbled. UPDATE CrossOver to 24+ (26+ ideal) before continuing —"
  echo "that fixes everything. (Or see docs/old-crossover-workarounds.md to fight it.)"
  read -r -p "Continue anyway? [y/N] " a; [ "$a" = y ] || exit 1
fi

if [ -z "$INSTALLER" ]; then
  INSTALLER="$(ls -t "$HOME/Downloads"/RaceStudio3-64_*.exe 2>/dev/null | head -1 || true)"
  [ -n "$INSTALLER" ] || { echo "No installer given and none found in ~/Downloads."; \
    echo "Download from https://www.aim-sportline.com/en/sw-fw-download.htm"; exit 1; }
fi
echo "Installer: $INSTALLER"

echo "==> creating Windows 10 bottle '$BOTTLE'…"
"$CX/bin/cxbottle" --bottle "$BOTTLE" --create --template win10_64 \
  --description "AiM RaceStudio 3" 2>&1 | tail -2 || true

echo "==> launching the installer. Click through the wizard (Next -> Install -> Finish)."
"$CX/bin/cxstart" --bottle "$BOTTLE" -- "$INSTALLER"

echo "==> if it installed, the app is at:"
echo "    C:\\AIM_SPORT\\RaceStudio3\\64\\AiMRS3-64-ReleaseU.exe"
echo "Launch later with:"
echo "    \"$CX/bin/cxstart\" --bottle $BOTTLE -- 'C:\\AIM_SPORT\\RaceStudio3\\64\\AiMRS3-64-ReleaseU.exe'"
echo "Run scripts/make-launcher.sh to get a double-clickable launcher."
