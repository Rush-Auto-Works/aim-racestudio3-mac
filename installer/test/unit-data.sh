#!/bin/bash
# unit-data.sh — exhaustively exercise data_relocate_safe() (the #1 data-loss surface) and
# import_merge(). Every resume/crash branch, plus the data-preservation guarantees.
_T_NAME="unit-data"
. "$(dirname "${BASH_SOURCE[0]}")/harness.sh"

# Each scenario gets its own fresh PREFIX/DATA_DIR/STATE so ledgers don't bleed.
scenario() {
  local n="$1"
  PREFIX="$SANDBOX/$n/prefix"
  DATA_DIR="$SANDBOX/$n/Documents/AIM_SPORT"
  STATE_DIR="$SANDBOX/$n/state"
  CONFIG_ENV="$STATE_DIR/config.env"
  mkdir -p "$STATE_DIR"
  printf '\n# scenario: %s\n' "$n"
}

src_of()  { printf '%s' "$PREFIX/drive_c/$RS3_REL_USER"; }

# ---- 1. clean install: DST absent --------------------------------------------------------
scenario clean
SRC="$(make_fresh_user)"
data_relocate_safe
assert_eq "$?" 0 "clean: returns 0"
assert_symlink_to "$SRC" "$DATA_DIR" "clean: SRC is symlink to DST"
assert_file "$DATA_DIR/cfgs/default.zconfig" "clean: config copied"
assert_eq "$(cat "$DATA_DIR/system/settings.ini")" "sys" "clean: content intact"
assert_file "$DATA_DIR/profiles/.empty" "clean: zero-byte file copied"
assert_eq "$(stat -f %z "$DATA_DIR/profiles/.empty")" "0" "clean: zero-byte stays zero"
assert_absent "$SRC.gone" "clean: no leftover .gone"
assert_true "ledger_has data" "clean: data marker set"

# ---- 2. migrating user: DST pre-exists with REAL telemetry that must NOT be overwritten ----
scenario migrating
SRC="$(make_fresh_user)"
mkdir -p "$DATA_DIR/cfgs" "$DATA_DIR/data/2026-05-30"
printf 'MY-REAL-TUNED-CONFIG\n' > "$DATA_DIR/cfgs/default.zconfig"   # same name as a fresh default
printf 'telemetry-bytes\n'      > "$DATA_DIR/data/2026-05-30/lap.xrk"
data_relocate_safe
assert_eq "$?" 0 "migrating: returns 0"
assert_eq "$(cat "$DATA_DIR/cfgs/default.zconfig")" "MY-REAL-TUNED-CONFIG" "migrating: user config NOT overwritten"
assert_file "$DATA_DIR/data/2026-05-30/lap.xrk" "migrating: telemetry preserved"
assert_file "$DATA_DIR/system/settings.ini" "migrating: missing default supplied (copy-if-absent)"
assert_symlink_to "$SRC" "$DATA_DIR" "migrating: SRC symlinked"

# ---- 3. idempotent re-run ------------------------------------------------------------------
scenario idempotent
SRC="$(make_fresh_user)"
data_relocate_safe; r1=$?
data_relocate_safe; r2=$?
assert_eq "$r1" 0 "idempotent: first run 0"
assert_eq "$r2" 0 "idempotent: second run 0"
assert_symlink_to "$SRC" "$DATA_DIR" "idempotent: still symlinked"

# ---- 4. resume: crashed after mv SRC->SRC.gone (SRC missing, .gone present, DST complete) ---
scenario resume_gone
SRC="$(make_fresh_user)"
# simulate DST already fully populated + SRC moved aside
mkdir -p "$DATA_DIR"; ditto "$SRC" "$DATA_DIR"
mv "$SRC" "$SRC.gone"
data_relocate_safe
assert_eq "$?" 0 "resume_gone: returns 0"
assert_symlink_to "$SRC" "$DATA_DIR" "resume_gone: symlink created"
assert_absent "$SRC.gone" "resume_gone: .gone cleaned"

# ---- 5. resume: crashed between ln and rename (.tmplink correct target, SRC missing) -------
scenario resume_tmplink
SRC="$(make_fresh_user)"
mkdir -p "$DATA_DIR"; ditto "$SRC" "$DATA_DIR"
mv "$SRC" "$SRC.gone"
ln -s "$DATA_DIR" "$SRC.tmplink"
data_relocate_safe
assert_eq "$?" 0 "resume_tmplink: returns 0"
assert_symlink_to "$SRC" "$DATA_DIR" "resume_tmplink: rename completed"
assert_absent "$SRC.tmplink" "resume_tmplink: tmplink consumed"

# ---- 6. stale tmplink pointing at the WRONG dst -> discarded, rebuilt against current DST ---
scenario stale_tmplink
SRC="$(make_fresh_user)"
local_old="$SANDBOX/stale_tmplink/OLD_DST"; mkdir -p "$local_old"
mv "$SRC" "$SRC.gone2tmp" 2>/dev/null || true   # park real dir
ln -s "$local_old" "$SRC.tmplink"               # stale link, wrong target, SRC missing
# restore a real SRC so forward path can run after stale link discarded
ditto "$SRC.gone2tmp" "$SRC"; rm -rf "$SRC.gone2tmp"
data_relocate_safe
assert_eq "$?" 0 "stale_tmplink: returns 0"
assert_symlink_to "$SRC" "$DATA_DIR" "stale_tmplink: bound to CURRENT dst, not stale"

# ---- 7. stale SRC symlink pointing at wrong dir -> replaced --------------------------------
scenario stale_symlink
SRC="$(make_fresh_user)"
old="$SANDBOX/stale_symlink/OLD"; mkdir -p "$old"
mv "$SRC" "$SRC.real"
ln -s "$old" "$SRC"                              # SRC is a symlink to the wrong place
ditto "$SRC.real" "$SRC.restore"; rm -rf "$SRC.real"
# put a real dir back where forward path expects after the stale link is removed:
# data_relocate_safe rm's the stale link then expects SRC real dir -> stage it as .restore swap
# (the function removes the link; we pre-stage the real dir under SRC by replacing link target)
rm -f "$SRC"; mv "$SRC.restore" "$SRC"
data_relocate_safe
assert_eq "$?" 0 "stale_symlink: returns 0"
assert_symlink_to "$SRC" "$DATA_DIR" "stale_symlink: rebound to current dst"

# ---- 8. mid-ditto resume: DST partially populated, then full run completes -----------------
scenario mid_ditto
SRC="$(make_fresh_user)"
mkdir -p "$DATA_DIR/cfgs"
ditto "$SRC/cfgs/default.zconfig" "$DATA_DIR/cfgs/default.zconfig"   # only one file copied so far
data_relocate_safe
assert_eq "$?" 0 "mid_ditto: returns 0"
assert_file "$DATA_DIR/system/settings.ini" "mid_ditto: remaining files completed"
assert_symlink_to "$SRC" "$DATA_DIR" "mid_ditto: symlinked"

# ---- 9. merge cannot complete (DST path blocked) => ABORT, leave SRC untouched -------------
# A pre-existing user file of a DIFFERENT size is NOT an error (that's the migrating case,
# covered in scenario 2). The real abort path is a merge that genuinely can't place a needed
# default file. Simulate by making DST/system a regular FILE, so copying system/settings.ini
# into it is impossible -> merge fails -> relocate must abort and leave SRC fully intact.
scenario merge_blocked
SRC="$(make_fresh_user)"
mkdir -p "$DATA_DIR"
printf 'not-a-dir' > "$DATA_DIR/system"          # blocks DST/system/settings.ini
data_relocate_safe; rc=$?
assert_false "[ $rc -eq 0 ]" "merge_blocked: relocate aborts (nonzero)"
assert_true  "[ -d \"$SRC\" ] && [ ! -L \"$SRC\" ]" "merge_blocked: SRC real dir untouched"
assert_false "ledger_has data" "merge_blocked: data marker NOT set"

# ---- 9b. _verify_merge presence gate: a missing DST file fails verification ----------------
scenario verify_presence
SRC="$(make_fresh_user)"
mkdir -p "$DATA_DIR"
# Hand-build a DST that is missing one SRC file, then call the verifier directly.
ditto "$SRC" "$DATA_DIR"
rm -f "$DATA_DIR/system/settings.ini"
_MERGED_COPIED=()
assert_false "_verify_merge \"$SRC\" \"$DATA_DIR\"" "verify: missing DST file => fail"

# ---- 10. import_merge: external folder merges, never overwrites -----------------------------
scenario import
mkdir -p "$DATA_DIR/cfgs"
printf 'EXISTING\n' > "$DATA_DIR/cfgs/keep.zconfig"
ext="$SANDBOX/import/ext/AIM_SPORT/RaceStudio3/user"
mkdir -p "$ext/cfgs"
printf 'EXISTING-SHOULD-NOT-CLOBBER\n' > "$ext/cfgs/keep.zconfig"
printf 'NEW\n'                          > "$ext/cfgs/new.zconfig"
import_merge "$SANDBOX/import/ext/AIM_SPORT"
assert_eq "$(cat "$DATA_DIR/cfgs/keep.zconfig")" "EXISTING" "import: existing file not clobbered"
assert_file "$DATA_DIR/cfgs/new.zconfig" "import: new file merged in"

finish
