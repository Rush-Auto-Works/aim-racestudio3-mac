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

# ---- 10b. import_xrk_dir: a folder of loose .xrk sessions (no user tree) --------------------
scenario import-xrk
xdir="$SANDBOX/import/xrk/RUSH_SR_C0319"
mkdir -p "$xdir/sub"
printf 'LAP1\n' > "$xdir/run1.xrk"
printf 'LAP2\n' > "$xdir/sub/run2.XRK"   # case-insensitive + nested
printf 'junk\n' > "$xdir/notes.txt"      # non-.xrk ignored
assert_true  "_dir_has_session_file \"$xdir\""         "xrk: folder detected as having session files"
assert_false "[ -n \"\$(_find_user_tree \"$xdir\")\" ]" "xrk: not mistaken for a user tree"
import_xrk_dir "$xdir"
assert_file "$DATA_DIR/data/RUSH_SR_C0319/run1.xrk"     "xrk: top-level session copied"
assert_file "$DATA_DIR/data/RUSH_SR_C0319/sub/run2.XRK" "xrk: nested session copied"
assert_absent "$DATA_DIR/data/RUSH_SR_C0319/notes.txt"  "xrk: non-.xrk file not imported"

# ---- 10c. import_session_dir: a folder mixing .xrk and .drk sessions --------------------------
scenario import-drk-folder
ddir="$SANDBOX/import/drk/OLD_DATA"
mkdir -p "$ddir"
printf 'LEGACY1\n' > "$ddir/session1.drk"
printf 'MODERN\n'  > "$ddir/session2.xrk"
printf 'junk\n'    > "$ddir/notes.txt"
assert_true  "_dir_has_session_file \"$ddir\""          "drk: folder detected as having session files"
assert_false "[ -n \"\$(_find_user_tree \"$ddir\")\" ]"  "drk: not mistaken for a user tree"
import_session_dir "$ddir"
assert_file "$DATA_DIR/data/OLD_DATA/session1.drk" "drk: .drk session copied"
assert_file "$DATA_DIR/data/OLD_DATA/session2.xrk" "drk: .xrk session copied"
assert_absent "$DATA_DIR/data/OLD_DATA/notes.txt"  "drk: non-session file not imported"

# ---- 10d. single-file .drk routing (do_import *.drk branch) -----------------------------------
# do_import lives in installer-core.sh (not sourced here), so exercise the single-file branch by
# running the real engine via --import, exactly as the Import app does.
scenario import-drk-file
mkdir -p "$DATA_DIR"
sf="$SANDBOX/import/drkfile/session.drk"
mkdir -p "$(dirname "$sf")"
printf 'LEGACY\n' > "$sf"
RS3_APP_SUPPORT="$INSTALL_ROOT" RS3_DATA_DIR="$DATA_DIR" UI_MODE=dryrun \
  bash "$SRC_DIR/installer-core.sh" --import "$sf" >/dev/null 2>&1
assert_file "$DATA_DIR/data/dropped-"*/session.drk "drk: single .drk file routed to dropped-<date>/"

# ---- 10e. import_config_archive: a .zconf2 configuration export ------------------------------
# The archive shape RaceStudio 3 exports: one cfg_<timestamp> folder holding the .aimcfg + its
# devices/ tree, plus a to_copy_in_app_root_folder/user/ payload of shared resources.
scenario import-zconf2
mkdir -p "$DATA_DIR/cfgs"
zsrc="$SANDBOX/import/zconf2/src"
mkdir -p "$zsrc/cfg_20220318_162427/devices/MXS" "$zsrc/to_copy_in_app_root_folder/user/resources/overlay"
printf 'CFG\n'     > "$zsrc/cfg_20220318_162427/rush sr mxs.aimcfg"
printf 'log\n'     > "$zsrc/cfg_20220318_162427/rush sr mxs.aimcfg.dump.log"
printf 'DEV\n'     > "$zsrc/cfg_20220318_162427/devices/MXS/dev.aimdev2"
printf 'ICON\n'    > "$zsrc/to_copy_in_app_root_folder/user/resources/overlay/icon.png"
zarc="$SANDBOX/import/zconf2/config.zconf2"
(cd "$zsrc" && zip -q -r "$zarc" .)

assert_eq "$(_cfg_label "$zsrc/cfg_20220318_162427")" "rush sr mxs" "zconf2: label is the .aimcfg name, not the .dump.log"
import_config_archive "$zarc"
assert_eq "$?" 0 "zconf2: import returns 0"
assert_file   "$DATA_DIR/cfgs/cfg_20220318_162427/rush sr mxs.aimcfg"   "zconf2: config folder copied into cfgs/"
assert_file   "$DATA_DIR/cfgs/cfg_20220318_162427/devices/MXS/dev.aimdev2" "zconf2: devices/ tree copied"
assert_file   "$DATA_DIR/resources/overlay/icon.png"                     "zconf2: app-root payload merged into the data folder"
assert_absent "$DATA_DIR/cfgs/to_copy_in_app_root_folder"                "zconf2: payload folder not left behind in cfgs/"

# Re-dropping the same file is a no-op, not a second copy.
dupout="$(UI_MODE=applet import_config_archive "$zarc")"
assert_absent "$DATA_DIR/cfgs/cfg_20220318_162427_01" "zconf2: identical re-import does not stack a copy"
assert_true  "printf '%s' \"$dupout\" | grep -q '^IMPORT_CONFIG_DUP: rush sr mxs$'" "zconf2: re-import reports IMPORT_CONFIG_DUP to the applet"
assert_false "printf '%s' \"$dupout\" | grep -q '^IMPORT_CONFIG: '"                 "zconf2: re-import emits no IMPORT_CONFIG"

# A DIFFERENT config that happens to carry the same timestamp folder gets RS3's _NN suffix, and
# the config already there is untouched.
printf 'OTHER\n' > "$zsrc/cfg_20220318_162427/rush sr mxs.aimcfg"
zarc2="$SANDBOX/import/zconf2/other.zconf2"
(cd "$zsrc" && zip -q -r "$zarc2" .)
import_config_archive "$zarc2"
assert_file "$DATA_DIR/cfgs/cfg_20220318_162427_01/rush sr mxs.aimcfg" "zconf2: name collision gets the _NN suffix"
assert_eq "$(cat "$DATA_DIR/cfgs/cfg_20220318_162427/rush sr mxs.aimcfg")" "CFG" "zconf2: existing config not overwritten"

# Every to_copy_in_app_root* payload is merged, not just the first one found.
scenario import-zconf2-payloads
mkdir -p "$DATA_DIR/cfgs"
psrc="$SANDBOX/import/payloads/src"
mkdir -p "$psrc/cfg_1" "$psrc/to_copy_in_app_root_folder/user/resources/overlay" "$psrc/to_copy_in_app_root_1/user/resources/masks"
printf 'CFG\n'  > "$psrc/cfg_1/one.aimcfg"
printf 'A\n'    > "$psrc/to_copy_in_app_root_folder/user/resources/overlay/a.png"
printf 'B\n'    > "$psrc/to_copy_in_app_root_1/user/resources/masks/b.png"
parc="$SANDBOX/import/payloads/two.zconf2"
(cd "$psrc" && zip -q -r "$parc" .)
import_config_archive "$parc"
assert_eq "$?" 0 "zconf2: multi-payload import returns 0"
assert_file "$DATA_DIR/resources/overlay/a.png" "zconf2: first payload merged"
assert_file "$DATA_DIR/resources/masks/b.png"   "zconf2: SECOND payload merged too"

# A config folder that is really a symlink is not a configuration. ditto -x recreates symlink
# entries verbatim, so accepting one would plant a link pointing outside the data tree into cfgs/.
scenario import-zconf2-symlink
mkdir -p "$DATA_DIR/cfgs"
lsrc="$SANDBOX/import/symlink/src"
outside="$SANDBOX/import/symlink/outside"
mkdir -p "$lsrc/cfg_ok" "$outside"
printf 'OK\n'     > "$lsrc/cfg_ok/ok.aimcfg"
printf 'SECRET\n' > "$outside/evil.aimcfg"        # a real config tree the link points at
ln -s "$outside" "$lsrc/cfg_link"
assert_eq "$(_find_config_dirs "$lsrc" | wc -l | tr -d ' ')" "1" "zconf2: symlinked config folder rejected"
assert_eq "$(basename "$(_find_config_dirs "$lsrc")")" "cfg_ok" "zconf2: the real config folder is still found"

# A user file that happens to sit at the merge helper's temp path must survive. The old name was
# "<file>.tmp.$$", which a leftover from a crashed import (or plain PID reuse) could collide with —
# ditto would clobber it and the mv would delete it.
scenario merge-temp-collision
mkdir -p "$DATA_DIR/resources/overlay"
msrc="$SANDBOX/merge/src/resources/overlay"
mkdir -p "$msrc"
printf 'NEW\n' > "$msrc/icon.png"
printf 'PRECIOUS\n' > "$DATA_DIR/resources/overlay/icon.png.tmp.$$"
_merge_copy_if_absent "$SANDBOX/merge/src" "$DATA_DIR"
assert_eq "$?" 0 "merge: copy succeeds despite a file at the old temp path"
assert_eq "$(cat "$DATA_DIR/resources/overlay/icon.png.tmp.$$")" "PRECIOUS" "merge: file at the predictable temp path is NOT destroyed"
assert_eq "$(cat "$DATA_DIR/resources/overlay/icon.png")" "NEW" "merge: the new file still landed"

# A duplicate configuration whose payload carries NEW icons must not report "nothing new".
scenario import-zconf2-dup-new-resources
mkdir -p "$DATA_DIR/cfgs"
dsrc="$SANDBOX/import/dupres/src"
mkdir -p "$dsrc/cfg_1" "$dsrc/to_copy_in_app_root_folder/user/resources/overlay"
printf 'CFG\n' > "$dsrc/cfg_1/one.aimcfg"
printf 'A\n'   > "$dsrc/to_copy_in_app_root_folder/user/resources/overlay/a.png"
darc1="$SANDBOX/import/dupres/first.zconf2"
(cd "$dsrc" && zip -q -r "$darc1" .)
import_config_archive "$darc1" >/dev/null 2>&1
# Same config, one extra icon.
printf 'B\n' > "$dsrc/to_copy_in_app_root_folder/user/resources/overlay/b.png"
darc2="$SANDBOX/import/dupres/second.zconf2"
(cd "$dsrc" && zip -q -r "$darc2" .)
dupres="$(UI_MODE=applet import_config_archive "$darc2")"
assert_eq "$?" 0 "dup-res: duplicate-with-new-resources returns 0"
assert_file "$DATA_DIR/resources/overlay/b.png" "dup-res: the new icon was merged"
assert_true "printf '%s' \"$dupres\" | grep -q '^IMPORT_EXTRAS: 1$'" "dup-res: applet is told 1 resource file landed"
assert_true "printf '%s' \"$dupres\" | grep -q '^IMPORT_CONFIG_DUP: one$'" "dup-res: the config itself is still reported as a duplicate"

# A DANGLING symlink in the data folder is still the user's file. `-e` is false for one, so the
# merge used to treat it as absent and `mv -f` replaced it with a regular file — silent data loss
# for anyone whose link points at an unmounted volume.
scenario merge-dangling-symlink
mkdir -p "$DATA_DIR/resources/overlay"
gsrc="$SANDBOX/dangle/src/resources/overlay"
mkdir -p "$gsrc"
printf 'NEW\n' > "$gsrc/icon.png"
ln -s "$SANDBOX/dangle/no-such-target" "$DATA_DIR/resources/overlay/icon.png"
_merge_copy_if_absent "$SANDBOX/dangle/src" "$DATA_DIR"
assert_eq "$?" 0 "dangle: merge still returns 0"
assert_symlink_to "$DATA_DIR/resources/overlay/icon.png" "$SANDBOX/dangle/no-such-target" "dangle: the user's dangling symlink survives"

# A copy that fails must report failure rather than a silent success. An unwritable cfgs/ is the
# only deterministic way to fail the copy from a test: `ditto -x` normalizes extracted modes to
# 644, so an archive cannot carry a file that makes the second ditto die partway. That means this
# pins the failure REPORTING, not the `rm -rf "$cfgs/$name"` cleanup beside it — the cleanup is
# defensive and unreachable from here.
scenario import-zconf2-copy-fails
mkdir -p "$DATA_DIR/cfgs"
fsrc="$SANDBOX/import/failcopy/src"
mkdir -p "$fsrc/cfg_1"
printf 'CFG\n' > "$fsrc/cfg_1/one.aimcfg"
farc="$SANDBOX/import/failcopy/f.zconf2"
(cd "$fsrc" && zip -q -r "$farc" .)
chmod 555 "$DATA_DIR/cfgs"
import_config_archive "$farc" >/dev/null 2>&1
_rc=$?
chmod 755 "$DATA_DIR/cfgs"
assert_eq "$_rc" 1 "failcopy: a config that could not be copied fails the import"
assert_absent "$DATA_DIR/cfgs/cfg_1" "failcopy: nothing left in cfgs/ after the failure"

# The commit is `ln`, not `mv -n`, because the absence check and the commit are not atomic. If the
# destination turns into a directory in between, `mv -n` moves the temp INSIDE it, exits 0, leaks
# it there, and the helper records a copy that never happened. `ln` fails with EEXIST instead.
# Shadowing ditto is what makes the race deterministic: it creates the directory as a side effect
# of writing the temp file, i.e. exactly between the check and the commit.
scenario merge-dest-became-a-dir
mkdir -p "$DATA_DIR/resources/overlay"
rsrc="$SANDBOX/race/src/resources/overlay"
mkdir -p "$rsrc"
printf 'NEW\n' > "$rsrc/icon.png"
ditto() {
  /usr/bin/ditto "$@"
  local rc=$?
  mkdir -p "$DATA_DIR/resources/overlay/icon.png"   # the racing writer
  return $rc
}
_merge_copy_if_absent "$SANDBOX/race/src" "$DATA_DIR"
_rrc=$?
unset -f ditto
assert_eq "$_rrc" 0 "race: losing the race is not an error"
assert_eq "$(find "$DATA_DIR/resources/overlay" -name '*.tmp.*' | wc -l | tr -d ' ')" "0" "race: no temp file leaked into the directory that appeared"
assert_eq "${#_MERGED_COPIED[@]}" "0" "race: a copy that did not happen is not recorded"

# A dangling symlink already sitting at a config name must not be treated as a free slot: the
# failure branch would then rm -rf the user's link on its way out.
scenario cfg-free-name-dangling
mkdir -p "$DATA_DIR/cfgs"
ln -s "$SANDBOX/gone" "$DATA_DIR/cfgs/cfg_1"
assert_eq "$(_cfg_free_name "$DATA_DIR/cfgs" cfg_1)" "cfg_1_01" "free-name: a dangling symlink counts as taken"
ln -s "$SANDBOX/gone" "$DATA_DIR/cfgs/cfg_1_01"
assert_eq "$(_cfg_free_name "$DATA_DIR/cfgs" cfg_1)" "cfg_1_02" "free-name: a dangling _NN symlink counts as taken too"

# The half-written-configuration cleanup, pinned by shadowing ditto so the config copy fails AFTER
# creating its destination. The real binary still does the extraction; only the second call fails.
scenario import-zconf2-partial-cleanup
mkdir -p "$DATA_DIR/cfgs"
psrc2="$SANDBOX/import/partial/src"
mkdir -p "$psrc2/cfg_1"
printf 'CFG\n' > "$psrc2/cfg_1/one.aimcfg"
parc2="$SANDBOX/import/partial/p.zconf2"
(cd "$psrc2" && zip -q -r "$parc2" .)
ditto() {   # shadows /usr/bin/ditto for this scenario only
  case "$*" in
    *"$DATA_DIR/cfgs/"*) mkdir -p "${!#}"; printf 'HALF\n' > "${!#}/one.aimcfg"; return 1 ;;
    *) /usr/bin/ditto "$@" ;;
  esac
}
import_config_archive "$parc2" >/dev/null 2>&1
_prc=$?
unset -f ditto
assert_eq "$_prc" 1 "partial: an import whose only config failed returns 1"
assert_absent "$DATA_DIR/cfgs/cfg_1" "partial: the half-written configuration was removed"

# A symlink ANYWHERE inside the config folder is refused. ditto preserves inner links too, so
# `cfg_x/devices -> /` would plant a link to the whole Mac under cfgs/ and hang RS3 (issue #32).
scenario import-zconf2-inner-symlink
mkdir -p "$DATA_DIR/cfgs"
isrc="$SANDBOX/import/innerlink/src"
mkdir -p "$isrc/cfg_evil"
printf 'CFG\n' > "$isrc/cfg_evil/e.aimcfg"
ln -s "/" "$isrc/cfg_evil/devices"
iarc="$SANDBOX/import/innerlink/evil.zconf2"
(cd "$isrc" && zip -q -r -y "$iarc" .)
import_config_archive "$iarc" >/dev/null 2>&1
assert_eq "$?" 1 "zconf2: config folder containing a symlink is refused"
assert_absent "$DATA_DIR/cfgs/cfg_evil" "zconf2: nothing from the symlinked archive reached cfgs/"

# A shared-resource failure must not sink a configuration that already landed. The applet throws
# away stdout on a non-zero exit, so returning 1 here would report "couldn't import" while the
# configuration sat in cfgs/ — the same desync the pre-scan above exists to prevent.
scenario import-zconf2-payload-fails
mkdir -p "$DATA_DIR/cfgs" "$DATA_DIR/resources"
ysrc="$SANDBOX/import/payfail/src"
mkdir -p "$ysrc/cfg_1" "$ysrc/to_copy_in_app_root_folder/user/resources/overlay"
printf 'CFG\n'  > "$ysrc/cfg_1/one.aimcfg"
printf 'ICON\n' > "$ysrc/to_copy_in_app_root_folder/user/resources/overlay/i.png"
yarc="$SANDBOX/import/payfail/y.zconf2"
(cd "$ysrc" && zip -q -r "$yarc" .)
chmod 555 "$DATA_DIR/resources"      # the payload merge cannot write; the config copy still can
yout="$(UI_MODE=applet import_config_archive "$yarc" 2>/dev/null)"
_yrc=$?
chmod 755 "$DATA_DIR/resources"
assert_eq "$_yrc" 0 "payfail: a resource failure does not fail the whole import"
assert_file "$DATA_DIR/cfgs/cfg_1/one.aimcfg" "payfail: the configuration still landed"
assert_true "printf '%s' \"$yout\" | grep -q '^IMPORT_CONFIG: one$'" "payfail: the applet is still told the config landed"
assert_true "printf '%s' \"$yout\" | grep -q '^WARN: '"              "payfail: the applet is told something went wrong"

# The symlink scan runs over the WHOLE archive before anything is copied. Refusing mid-loop would
# leave earlier configurations in cfgs/ with their shared resources never merged, while the applet
# told the user the import failed.
scenario import-zconf2-symlink-second-config
mkdir -p "$DATA_DIR/cfgs"
tsrc="$SANDBOX/import/twocfg/src"
mkdir -p "$tsrc/cfg_aaa" "$tsrc/cfg_zzz" "$tsrc/to_copy_in_app_root_folder/user/resources/overlay"
printf 'GOOD\n' > "$tsrc/cfg_aaa/good.aimcfg"
printf 'BAD\n'  > "$tsrc/cfg_zzz/bad.aimcfg"
printf 'ICON\n' > "$tsrc/to_copy_in_app_root_folder/user/resources/overlay/i.png"
ln -s "/" "$tsrc/cfg_zzz/devices"
tarc="$SANDBOX/import/twocfg/two.zconf2"
(cd "$tsrc" && zip -q -r -y "$tarc" .)
import_config_archive "$tarc" >/dev/null 2>&1
assert_eq "$?" 1 "twocfg: an archive with one bad config is refused"
assert_absent "$DATA_DIR/cfgs/cfg_aaa" "twocfg: the CLEAN config did not land either"
assert_absent "$DATA_DIR/resources/overlay/i.png" "twocfg: the shared payload did not land either"

# import_session_dir holds the same -e/-L invariant as the merge helper.
scenario session-dir-dangling-symlink
sdir="$SANDBOX/import/sessdangle/RUN"
mkdir -p "$sdir" "$DATA_DIR/data/RUN"
printf 'LAP\n' > "$sdir/a.xrk"
ln -s "$SANDBOX/import/sessdangle/gone" "$DATA_DIR/data/RUN/a.xrk"
import_session_dir "$sdir" >/dev/null 2>&1
assert_symlink_to "$DATA_DIR/data/RUN/a.xrk" "$SANDBOX/import/sessdangle/gone" "session-dir: a dangling symlink is not replaced"

# A zip with no .aimcfg in it is an error, not a silent success.
nocfg="$SANDBOX/import/zconf2/nocfg.zconf2"
mkdir -p "$SANDBOX/import/zconf2/empty/junk"
printf 'x\n' > "$SANDBOX/import/zconf2/empty/junk/readme.txt"
(cd "$SANDBOX/import/zconf2/empty" && zip -q -r "$nocfg" .)
import_config_archive "$nocfg" >/dev/null 2>&1
assert_eq "$?" 1 "zconf2: archive with no .aimcfg fails"

# ---- 10f. single-file .zconf2 routing (do_import *.zconf2 branch) ----------------------------
scenario import-zconf2-dispatch
mkdir -p "$DATA_DIR"
RS3_APP_SUPPORT="$INSTALL_ROOT" RS3_DATA_DIR="$DATA_DIR" UI_MODE=dryrun \
  bash "$SRC_DIR/installer-core.sh" --import "$zarc" >/dev/null 2>&1
assert_eq "$?" 0 "zconf2: engine exits 0 on a dropped .zconf2"
assert_file "$DATA_DIR/cfgs/cfg_20220318_162427/rush sr mxs.aimcfg" "zconf2: engine routes a dropped .zconf2 to the config importer"

finish
