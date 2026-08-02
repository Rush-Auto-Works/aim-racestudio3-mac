#!/bin/bash
# unit-collect-logs.sh — collect-logs.sh copies the logs that exist into a fresh Desktop folder,
# writes system-info.txt + README.txt, opens the folder, and never fails when a log is absent.
# Everything is sandboxed via env overrides (RS3_APP_SUPPORT, RS3_DESKTOP_DIR, RS3_OPEN_CMD).
_T_NAME="unit-collect-logs"
HERE="$(cd "$(dirname "$0")" && pwd)"
. "$HERE/harness.sh"

SCRIPT="$HERE/../src/collect-logs.sh"
assert_file "$SCRIPT"
assert_true "bash -n '$SCRIPT'" "collect-logs.sh parses"

# Fixture: an INSTALL_ROOT with run.log present but install.log ABSENT (tests the skip path).
ROOT="$SANDBOX/appsupport"
mkdir -p "$ROOT/logs"
printf 'run-log-marker\n' > "$ROOT/logs/run.log"

DESK="$SANDBOX/desktop"; mkdir -p "$DESK"
OPENLOG="$SANDBOX/open-called.txt"

# RS3_OPEN_CMD records its argument instead of launching Finder.
cat > "$SANDBOX/fake-open.sh" <<EOF
#!/bin/bash
printf '%s\n' "\$1" > "$OPENLOG"
EOF
chmod +x "$SANDBOX/fake-open.sh"

RS3_APP_SUPPORT="$ROOT" RS3_DESKTOP_DIR="$DESK" RS3_OPEN_CMD="$SANDBOX/fake-open.sh" \
  bash "$SCRIPT"
rc=$?
assert_true "[ $rc -eq 0 ]" "collect-logs.sh exits 0 even with install.log absent"

OUT="$(find "$DESK" -maxdepth 1 -type d -name 'AiM-Logs-*' | head -1)"
assert_true "[ -n '$OUT' ]" "a dated AiM-Logs-* folder was created"
assert_true "[ -f '$OUT/run.log' ]"          "present run.log was copied"
assert_true "grep -q run-log-marker '$OUT/run.log'" "run.log content intact"
assert_true "[ ! -f '$OUT/install.log' ]"    "absent install.log was skipped (not faked)"
assert_true "[ -f '$OUT/system-info.txt' ]"  "system-info.txt written"
assert_true "[ -f '$OUT/README.txt' ]"       "README.txt written"
assert_true "grep -q 'install.log' '$OUT/README.txt'" "README notes the missing install.log"
assert_true "grep -q 'aim-bridge.log' '$OUT/README.txt'" "README notes the missing aim-bridge.log"
assert_true "[ \"\$(cat '$OPENLOG' 2>/dev/null)\" = '$OUT' ]" "open was called on the output folder"

# --- version reporting ----------------------------------------------------------------------
# The old report printed only RS3_PINNED_VER, so a support log claimed the pinned version no
# matter what was installed. That is what hid the "DMG upgrade doesn't update RS3" bug.
FIX="$HERE/fixtures/RaceStudio3-3.83.26.xmv"
mkdir -p "$ROOT/prefix/drive_c/AIM_SPORT/RaceStudio3"
ditto "$FIX" "$ROOT/prefix/drive_c/AIM_SPORT/RaceStudio3/RaceStudio3.xmv"

DESK2="$SANDBOX/desktop2"; mkdir -p "$DESK2"
RS3_APP_SUPPORT="$ROOT" RS3_DESKTOP_DIR="$DESK2" RS3_OPEN_CMD="$SANDBOX/fake-open.sh" \
  bash "$SCRIPT"
OUT2="$(find "$DESK2" -maxdepth 1 -type d -name 'AiM-Logs-*' | head -1)"
SI="$OUT2/system-info.txt"
assert_true "grep -q 'RS3 version (installed): 3.83.26.0' '$SI'" "reports the INSTALLED version"
assert_true "grep -q 'RS3 version (pinned):' '$SI'"               "reports the pinned version too"
assert_true "grep -q 'installed differs from pinned' '$SI'"       "flags the mismatch"

# With no manifest, it says unknown — it must never fall back to claiming the pin.
ROOT3="$SANDBOX/appsupport3"; mkdir -p "$ROOT3/logs"
DESK3="$SANDBOX/desktop3"; mkdir -p "$DESK3"
RS3_APP_SUPPORT="$ROOT3" RS3_DESKTOP_DIR="$DESK3" RS3_OPEN_CMD="$SANDBOX/fake-open.sh" \
  bash "$SCRIPT"
OUT3="$(find "$DESK3" -maxdepth 1 -type d -name 'AiM-Logs-*' | head -1)"
assert_true "grep -q 'RS3 version (installed): unknown' '$OUT3/system-info.txt'" \
  "no manifest reports unknown, not the pin"

# Controlled pins live beside a sandbox copy because collect-logs.sh deliberately resolves
# pins.env relative to its own embedded-app location, not from an environment override.
CONTROLLED_SCRIPT="$SANDBOX/collect-logs.sh"
cp "$SCRIPT" "$CONTROLLED_SCRIPT"
chmod +x "$CONTROLLED_SCRIPT"
printf 'RS3_PINNED_VER="3.83.26"\nRS3_PKG_REV="1"\n' > "$SANDBOX/pins.env"

# Both three-field and AiM's equivalent four-field installed versions match the same pin.
ROOTA="$SANDBOX/appsupport-a"; mkdir -p "$ROOTA/prefix/drive_c/AIM_SPORT/RaceStudio3"
sed 's|3\.83\.26\.0|3.83.26|' "$FIX" > \
  "$ROOTA/prefix/drive_c/AIM_SPORT/RaceStudio3/RaceStudio3.xmv"
DESKA="$SANDBOX/desktop-a"; mkdir -p "$DESKA"
RS3_APP_SUPPORT="$ROOTA" RS3_DESKTOP_DIR="$DESKA" RS3_OPEN_CMD="$SANDBOX/fake-open.sh" \
  bash "$CONTROLLED_SCRIPT"
OUTA="$(find "$DESKA" -maxdepth 1 -type d -name 'AiM-Logs-*' | head -1)"
SIA="$OUTA/system-info.txt"
assert_true "grep -q 'RS3 version (installed): 3.83.26$' '$SIA'" \
  "three-field installed version matches pin"
assert_false "grep -q 'installed differs from pinned' '$SIA'" \
  "three-field match has no mismatch warning"

ROOTA4="$SANDBOX/appsupport-a4"; mkdir -p "$ROOTA4/prefix/drive_c/AIM_SPORT/RaceStudio3"
cp "$FIX" "$ROOTA4/prefix/drive_c/AIM_SPORT/RaceStudio3/RaceStudio3.xmv"
DESKA4="$SANDBOX/desktop-a4"; mkdir -p "$DESKA4"
RS3_APP_SUPPORT="$ROOTA4" RS3_DESKTOP_DIR="$DESKA4" RS3_OPEN_CMD="$SANDBOX/fake-open.sh" \
  bash "$CONTROLLED_SCRIPT"
OUTA4="$(find "$DESKA4" -maxdepth 1 -type d -name 'AiM-Logs-*' | head -1)"
SIA4="$OUTA4/system-info.txt"
assert_true "grep -q 'RS3 version (installed): 3.83.26.0$' '$SIA4'" \
  "four-field installed version is reported"
assert_false "grep -q 'installed differs from pinned' '$SIA4'" \
  "four-field .0 equivalent has no mismatch warning"

# A malformed RS3_PINNED_VER is unknown even when the installed manifest is valid.
printf 'RS3_PINNED_VER="not-a-version"\nRS3_PKG_REV="1"\n' > "$SANDBOX/pins.env"
ROOTPIN="$SANDBOX/appsupport-pin"; mkdir -p "$ROOTPIN/prefix/drive_c/AIM_SPORT/RaceStudio3"
cp "$FIX" "$ROOTPIN/prefix/drive_c/AIM_SPORT/RaceStudio3/RaceStudio3.xmv"
DESKPIN="$SANDBOX/desktop-pin"; mkdir -p "$DESKPIN"
RS3_APP_SUPPORT="$ROOTPIN" RS3_DESKTOP_DIR="$DESKPIN" RS3_OPEN_CMD="$SANDBOX/fake-open.sh" \
  bash "$CONTROLLED_SCRIPT"
rc=$?
OUTPIN="$(find "$DESKPIN" -maxdepth 1 -type d -name 'AiM-Logs-*' | head -1)"
SIPIN="$OUTPIN/system-info.txt"
assert_true "[ $rc -eq 0 ]" "malformed pinned version still exits 0"
assert_true "grep -q 'RS3 version (installed): 3.83.26.0' '$SIPIN'" \
  "malformed pin scenario has a valid installed version"
assert_true "grep -q 'RS3 version (pinned):    unknown' '$SIPIN'" \
  "malformed pinned version reports unknown"
assert_false "grep -q 'not-a-version' '$SIPIN'" \
  "malformed pinned version is not printed"
assert_false "grep -q 'installed differs from pinned' '$SIPIN'" \
  "malformed pinned version has no mismatch warning"

# A malformed VERSION is unknown and cannot trigger a mismatch diagnosis.
ROOTB="$SANDBOX/appsupport-b"; mkdir -p "$ROOTB/prefix/drive_c/AIM_SPORT/RaceStudio3"
printf '%s\n' '<p n="VERSION">not-a-version</p>' > \
  "$ROOTB/prefix/drive_c/AIM_SPORT/RaceStudio3/RaceStudio3.xmv"
DESKB="$SANDBOX/desktop-b"; mkdir -p "$DESKB"
RS3_APP_SUPPORT="$ROOTB" RS3_DESKTOP_DIR="$DESKB" RS3_OPEN_CMD="$SANDBOX/fake-open.sh" \
  bash "$CONTROLLED_SCRIPT"
OUTB="$(find "$DESKB" -maxdepth 1 -type d -name 'AiM-Logs-*' | head -1)"
SIB="$OUTB/system-info.txt"
assert_true "grep -q 'RS3 version (installed): unknown' '$SIB'" \
  "malformed installed version reports unknown"
assert_false "grep -q 'not-a-version' '$SIB'" \
  "malformed installed version is not printed"
assert_false "grep -q 'installed differs from pinned' '$SIB'" \
  "malformed installed version has no mismatch warning"

# Missing pins.env is still a reported unknown, and the collector remains best-effort.
rm -f "$SANDBOX/pins.env"
ROOTC="$SANDBOX/appsupport-c"; mkdir -p "$ROOTC/logs"
DESKC="$SANDBOX/desktop-c"; mkdir -p "$DESKC"
RS3_APP_SUPPORT="$ROOTC" RS3_DESKTOP_DIR="$DESKC" RS3_OPEN_CMD="$SANDBOX/fake-open.sh" \
  bash "$CONTROLLED_SCRIPT"
rc=$?
OUTC="$(find "$DESKC" -maxdepth 1 -type d -name 'AiM-Logs-*' | head -1)"
SIC="$OUTC/system-info.txt"
assert_true "[ $rc -eq 0 ]" "missing pins.env still exits 0"
assert_true "grep -q 'RS3 version (pinned):    unknown' '$SIC'" \
  "missing pins.env reports an unknown pinned version"

# A pins.env without RS3_PINNED_VER is also noted rather than rendered as a blank fact.
printf 'RS3_PKG_REV="1"\n' > "$SANDBOX/pins.env"
ROOTD="$SANDBOX/appsupport-d"; mkdir -p "$ROOTD/logs"
DESKD="$SANDBOX/desktop-d"; mkdir -p "$DESKD"
RS3_APP_SUPPORT="$ROOTD" RS3_DESKTOP_DIR="$DESKD" RS3_OPEN_CMD="$SANDBOX/fake-open.sh" \
  bash "$CONTROLLED_SCRIPT"
rc=$?
OUTD="$(find "$DESKD" -maxdepth 1 -type d -name 'AiM-Logs-*' | head -1)"
SID="$OUTD/system-info.txt"
assert_true "[ $rc -eq 0 ]" "pins.env without RS3_PINNED_VER still exits 0"
assert_true "grep -q 'RS3 version (pinned):    unknown' '$SID'" \
  "pins.env without RS3_PINNED_VER reports unknown"

finish
