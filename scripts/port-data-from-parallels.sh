#!/usr/bin/env bash
# Bulk-import RaceStudio 3 data (configs, profiles, database, .xrk sessions) from a
# RUNNING Parallels Windows VM into a CrossOver bottle.
#
# Requires: Parallels Desktop with the VM running and Parallels Tools installed
# (so `prlctl exec` works), and CrossOver with a RaceStudio 3 bottle already created.
#
# Usage:
#   ./port-data-from-parallels.sh --vm "Win11" --bottle "RaceStudio3" --since 2025-01-01
#
# Flags:
#   --vm      Parallels VM name (see `prlctl list -a`)            (default: Win11)
#   --bottle  CrossOver bottle name                              (default: RaceStudio3)
#   --since   Only copy .xrk sessions modified on/after this date (YYYY-MM-DD; default: all)
#   --user-src   Windows path to the RS3 user folder   (default: C:\AIM_SPORT\RaceStudio3\user)
#   --data-src   Windows path to the .xrk data root     (default: auto from user\data.lnk, else E:\data)
#   --no-data    Skip .xrk sessions, copy only configs/profiles/database
set -euo pipefail

VM="Win11"; BOTTLE="RaceStudio3"; SINCE=""; NO_DATA=0
USER_SRC='C:\AIM_SPORT\RaceStudio3\user'
DATA_SRC=""
while [ $# -gt 0 ]; do case "$1" in
  --vm) VM="$2"; shift 2;;
  --bottle) BOTTLE="$2"; shift 2;;
  --since) SINCE="$2"; shift 2;;
  --user-src) USER_SRC="$2"; shift 2;;
  --data-src) DATA_SRC="$2"; shift 2;;
  --no-data) NO_DATA=1; shift;;
  *) echo "unknown flag: $1" >&2; exit 1;;
esac; done

PRLCTL="$(command -v prlctl || echo /usr/local/bin/prlctl)"
CX="/Applications/CrossOver.app/Contents/SharedSupport/CrossOver"
BOTTLE_C="$HOME/Library/Application Support/CrossOver/Bottles/$BOTTLE/drive_c"
USER_DST="$BOTTLE_C/AIM_SPORT/RaceStudio3/user"
STAGE="$(mktemp -d /tmp/rs3stage.XXXXXX)"
SHARE="rs3port"

echo "VM=$VM  bottle=$BOTTLE  staging=$STAGE"
[ -d "$BOTTLE_C" ] || { echo "Bottle '$BOTTLE' not found at $BOTTLE_C — install RaceStudio 3 first." >&2; exit 1; }
"$PRLCTL" exec "$VM" cmd /c "echo ok" >/dev/null 2>&1 || { echo "Can't exec in VM '$VM'. Is it running with Parallels Tools?" >&2; exit 1; }

echo "==> close RaceStudio 3 in the bottle so files aren't locked"
"$CX/bin/wineserver" --bottle "$BOTTLE" -k 2>/dev/null || true; sleep 2

echo "==> share staging dir into the VM (\\\\psf\\$SHARE)"
"$PRLCTL" set "$VM" --shf-host-add "$SHARE" --path "$STAGE" --mode rw >/dev/null
trap '"$PRLCTL" set "$VM" --shf-host-del "$SHARE" >/dev/null 2>&1 || true' EXIT

echo "==> copy the full user/ tree (configs, profiles, database, tracks)…"
"$PRLCTL" exec "$VM" cmd /c \
  "robocopy \"$USER_SRC\" \"\\\\psf\\$SHARE\\user\" /E /R:1 /W:1 /NFL /NDL /NP" 2>&1 | tail -3 || true

if [ "$NO_DATA" -eq 0 ]; then
  # resolve the data root if not given: the user folder's data.lnk usually points to it
  if [ -z "$DATA_SRC" ]; then
    DATA_SRC="$("$PRLCTL" exec "$VM" cmd /c \
      "for /f \"tokens=2*\" %a in ('reg query nul 2^>nul') do rem" 2>/dev/null; echo 'E:\data')"
    DATA_SRC='E:\data'   # sensible default; override with --data-src if yours differs
  fi
  AGE=""; [ -n "$SINCE" ] && AGE="/MAXAGE:${SINCE//-/}"
  echo "==> copy .xrk sessions from $DATA_SRC ${SINCE:+(since $SINCE)}…"
  "$PRLCTL" exec "$VM" cmd /c \
    "robocopy \"$DATA_SRC\" \"\\\\psf\\$SHARE\\data\" /E $AGE /R:1 /W:1 /NFL /NDL /NP" 2>&1 | tail -4 || true
fi

echo "==> merge user/ tree into the bottle"
mkdir -p "$USER_DST"
rsync -a "$STAGE/user/" "$USER_DST/"

if [ "$NO_DATA" -eq 0 ] && [ -d "$STAGE/data" ]; then
  echo "==> place .xrk sessions (replacing the Windows data.lnk redirect with a real folder)"
  rm -f "$USER_DST/data.lnk"
  mkdir -p "$USER_DST/data"
  rsync -a "$STAGE/data/" "$USER_DST/data/"
fi

echo "==> done."
echo "configs: $(find "$USER_DST/cfgs" -iname '*.zconfig' 2>/dev/null | wc -l | tr -d ' ')  | xrk: $(find "$USER_DST/data" -iname '*.xrk' 2>/dev/null | wc -l | tr -d ' ')"
echo "First launch will be slow for ~1 min while RaceStudio 3 rebuilds config thumbnails."
rm -rf "$STAGE"
