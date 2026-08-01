# Part A — Make a DMG Upgrade Actually Update RaceStudio 3

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Installing a newer DMG over an existing install upgrades RaceStudio 3 to the pinned version, instead of silently keeping the old one.

**Architecture:** Teach the engine what version is actually installed by reading AiM's own manifest (`RaceStudio3.xmv`) inside the Wine prefix, add one three-way version comparator, and use those two facts at the three places that currently short-circuit: the remembered-installer check, the `installed` ledger postcondition, and the diagnostics report. The launcher app gains a third startup state (`RS3_OUTDATED`) so an upgrade runs the install phases with update-appropriate copy rather than a "first time" welcome.

**Tech Stack:** bash (macOS system bash 3.2), AppleScript (osacompile applet), the repo's own test harness (`installer/test/harness.sh`).

Source spec: `docs/superpowers/specs/2026-08-01-rs3-updater-design.md` (Part A only — Part B is a separate plan).

## Global Constraints

- **Target bash is macOS system bash 3.2.** No associative arrays, no `${var^^}`/`${var,,}`, no `mapfile`. Indexed arrays, `${var//x/y}` and `for (( ))` are fine.
- **BSD userland.** `stat -f %z` (never `-c`). `sed -E` (never `-r`).
- **No blanket `set -e`.** The engine is `set -uo pipefail`; callers check postconditions, not `$?`. Do not add `set -e` to any file.
- **`$(...)` strips trailing newlines.** This bit three separate times in the previous session. Never use command substitution to compare file contents; use `cmp -s`.
- **Every commit goes through the `commit-and-verify` skill.** A PreToolUse hook hard-blocks a direct `git commit`. Invoke the skill; it owns the commit. Reference the task number in the message.
- **Run `bash installer/test/run-all.sh` before every commit.** Baseline before this plan is 15 test files, all passing.
- **Do not add a `z:` drive to the prefix** under any circumstances (issue #32, `CLAUDE.md`).
- **Never make any of this overwrite user data.** `$DATA_DIR` is untouched by every change in this plan.
- Version strings in this repo exist in four shapes and all four must compare correctly:
  `3.83.39` (pins.env), `3.83.26.0` (RaceStudio3.xmv), `v3.83.39-1` (release tag), `3.83.39.1` (CFBundleVersion).

## File Structure

| File | Change | Responsibility |
|---|---|---|
| `installer/src/pins.env` | modify | add `RS3_REL_XMV` (path of AiM's manifest inside the prefix) |
| `installer/src/lib/wine.sh` | modify | `_ver_fields`, `ver_cmp`, `rs3_installed_ver`, `rs3_installed_at_least` |
| `installer/src/lib/net.sh` | modify | `verify_local_asset` (name+size+sha gate for locally-sourced files) |
| `installer/src/lib/ui.sh` | modify | `ui_forget` (drop one persisted key) |
| `installer/src/lib/ledger.sh` | modify | version-aware `installed` postcondition; `ledger_reset_for_reinstall` |
| `installer/src/installer-core.sh` | modify | acquire gate, `do_reinstall` reset, `install-state` action |
| `installer/src/collect-logs.sh` | modify | report installed version separately from pinned |
| `installer/src/RaceStudio3.applescript` | modify | three-state startup; name the required file in the picker |
| `installer/test/fixtures/RaceStudio3-3.83.26.xmv` | create | real captured AiM manifest |
| `installer/test/unit-version.sh` | create | `ver_cmp` / `rs3_installed_ver` / `rs3_installed_at_least` |
| `installer/test/unit-acquire.sh` | create | `phase_acquire_installer` accept/reject, hermetic (no network) |
| `installer/test/unit-net.sh` | modify | `verify_local_asset` cases |
| `installer/test/unit-ledger.sh` | modify | version-aware `installed`, `ledger_reset_for_reinstall` |
| `installer/test/unit-collect-logs.sh` | modify | installed-vs-pinned reporting |
| `installer/test/run-all.sh` | modify | register the two new test files |
| `installer/test/scenarios.md` | modify | manual upgrade scenario |
| `CHANGELOG.md` | modify | `[3.83.39-2]` entry |

**Deviation from the spec, deliberate:** the spec says `rs3_installed_ver` normalises `3.83.26.0` → `3.83.26`. It does not. Stripping the fourth field throws away real information the day AiM ships a non-zero one, and `ver_cmp` already zero-pads unequal field counts, so normalising buys nothing. `rs3_installed_ver` returns exactly what AiM wrote.

---

### Task 1: Version primitives and a real fixture

**Files:**
- Modify: `installer/src/pins.env` (after line 37, the `RS3_REL_USER` line)
- Modify: `installer/src/lib/wine.sh` (append at end of file)
- Create: `installer/test/fixtures/RaceStudio3-3.83.26.xmv`
- Create: `installer/test/unit-version.sh`
- Modify: `installer/test/run-all.sh:7`

**Interfaces:**
- Consumes: `PREFIX`, `RS3_REL_XMV` (pins.env).
- Produces, relied on by Tasks 2, 4, 6:
  - `ver_cmp <a> <b>` → prints `lt`|`eq`|`gt` on stdout, returns 0; returns 1 printing nothing when either side has a non-numeric field.
  - `rs3_installed_ver [xmv_path]` → prints the installed version (e.g. `3.83.26.0`), returns 0; returns 1 printing nothing when the file, the tag, or a sane value is missing.
  - `rs3_installed_at_least <want>` → returns 0 when installed >= want, 1 otherwise (including unknown).

- [ ] **Step 1: Capture the real fixture**

The manifest exists on this Mac. Copy it verbatim (it is 517 bytes, CRLF line endings — do not reformat it):

```bash
mkdir -p installer/test/fixtures
ditto "$HOME/Library/Application Support/RaceStudio3/prefix/drive_c/AIM_SPORT/RaceStudio3/RaceStudio3.xmv" \
      installer/test/fixtures/RaceStudio3-3.83.26.xmv
file installer/test/fixtures/RaceStudio3-3.83.26.xmv
```

Expected from `file`: `XML 1.0 document text, ASCII text, with CRLF line terminators`.

If that path no longer exists, write the file with exactly this content (CRLF, no trailing newline after the closing tag):

```xml
<?xml version="1.0"?>
<info_version_sw>
  <e c="InfoSW" i="InfoSW.1">
    <p n="BUILD_DATE_TIME">20260613_071826</p>
    <p n="BUILD_NUMBER">20260613.1</p>
    <p n="VERSION">3.83.26.0</p>
    <p n="EXE_NAME">RaceStudio3-64_38326_000000_000000_20260613_071826.exe</p>
    <p n="PRODUCT_NAME">RaceStudio3</p>
    <p n="MAJOR">3</p>
    <p n="MINOR">83</p>
    <p n="REVISION">26</p>
    <p n="SVN_FWSW2">000000</p>
    <p n="SVN_SOFTWARE">000000</p>
    <p n="TYPE">release</p>
  </e>
</info_version_sw>
```

- [ ] **Step 2: Add the manifest path to pins.env**

Insert directly after the `RS3_REL_USER` line:

```bash
# AiM's own version manifest inside the prefix (relative to drive_c). Their installer writes it,
# so it stays accurate even if RaceStudio 3's in-app updater replaces the build behind our back —
# which is why it, and not a marker of our own, is the source of truth for "what is installed".
RS3_REL_XMV="AIM_SPORT/RaceStudio3/RaceStudio3.xmv"
```

- [ ] **Step 3: Write the failing test**

Create `installer/test/unit-version.sh`:

```bash
#!/bin/bash
# unit-version.sh — the version primitives. Four representations ship in this repo
# (pins.env "3.83.39", RaceStudio3.xmv "3.83.26.0", release tag "v3.83.39-1",
# CFBundleVersion "3.83.39.1") and a naive string compare gets every cross-pair wrong.
_T_NAME="unit-version"
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
. "$HERE/harness.sh"

FIX="$HERE/fixtures/RaceStudio3-3.83.26.xmv"
assert_file "$FIX"

# ---- ver_cmp -------------------------------------------------------------------------------
assert_eq "$(ver_cmp 3.83.26 3.83.39)" lt "older is lt"
assert_eq "$(ver_cmp 3.83.39 3.83.26)" gt "newer is gt"
assert_eq "$(ver_cmp 3.83.39 3.83.39)" eq "same is eq"
assert_eq "$(ver_cmp 3.84.0 3.83.39)"  gt "minor bump beats a big patch number"
assert_eq "$(ver_cmp 3.9.0 3.10.0)"    lt "numeric, not lexical, field compare"
# unequal field counts: the missing field is zero, not 'smaller'
assert_eq "$(ver_cmp 3.83.39 3.83.39.0)" eq "trailing .0 is eq"
assert_eq "$(ver_cmp 3.83.39.1 3.83.39)" gt "trailing .1 is gt"
# the two shapes build-apps.sh emits for the SAME build must compare equal
assert_eq "$(ver_cmp v3.83.39-1 3.83.39.1)" eq "release tag == CFBundleVersion"
assert_eq "$(ver_cmp v3.83.39-2 v3.83.39-1)" gt "pkg rev is a real field"
# leading zeros must not be read as octal
assert_eq "$(ver_cmp 3.83.08 3.83.7)" gt "leading zero compares base-10"
# garbage is refused, not guessed
assert_false "ver_cmp 3.83.x 3.83.39" "non-numeric field returns nonzero"
assert_eq "$(ver_cmp 3.83.x 3.83.39)" "" "non-numeric field prints nothing"

# ---- rs3_installed_ver ---------------------------------------------------------------------
assert_eq "$(rs3_installed_ver "$FIX")" "3.83.26.0" "reads VERSION from the real manifest"

MISSING="$SANDBOX/nope.xmv"
assert_false "rs3_installed_ver '$MISSING'" "missing file returns nonzero"
assert_eq "$(rs3_installed_ver "$MISSING")" "" "missing file prints nothing"

NOTAG="$SANDBOX/notag.xmv"
printf '<?xml version="1.0"?>\r\n<info_version_sw>\r\n</info_version_sw>' > "$NOTAG"
assert_false "rs3_installed_ver '$NOTAG'" "manifest without a VERSION tag returns nonzero"

JUNK="$SANDBOX/junk.xmv"
printf '<p n="VERSION">not.a.version</p>\r\n' > "$JUNK"
assert_false "rs3_installed_ver '$JUNK'" "non-version value is refused"

TRUNC="$SANDBOX/trunc.xmv"
printf '<p n="VERSION">3.83</p>\r\n' > "$TRUNC"
assert_false "rs3_installed_ver '$TRUNC'" "two-field value is refused (needs 3 or 4)"

THREE="$SANDBOX/three.xmv"
printf '<p n="VERSION">3.83.26</p>\r\n' > "$THREE"
assert_eq "$(rs3_installed_ver "$THREE")" "3.83.26" "three-field value is accepted"

# ---- rs3_installed_at_least (reads $PREFIX/drive_c/$RS3_REL_XMV) ----------------------------
mkdir -p "$PREFIX/drive_c/$(dirname "$RS3_REL_XMV")"
assert_false "rs3_installed_at_least 3.83.39" "unknown install is NOT satisfied"

ditto "$FIX" "$PREFIX/drive_c/$RS3_REL_XMV"
assert_false "rs3_installed_at_least 3.83.39" "3.83.26.0 installed vs 3.83.39 wanted: not satisfied"
assert_true  "rs3_installed_at_least 3.83.26" "equal version is satisfied"
assert_true  "rs3_installed_at_least 3.82.0"  "newer than wanted is satisfied (never downgrade)"

finish
```

- [ ] **Step 4: Run it and confirm it fails**

Run: `bash installer/test/unit-version.sh`
Expected: FAIL — `ver_cmp: command not found` / many failed assertions. (Do not proceed if it passes; that would mean the functions already exist.)

- [ ] **Step 5: Implement the primitives**

Append to `installer/src/lib/wine.sh`:

```bash
# _ver_fields <ver> : print a version's numeric fields, space-separated. Accepts every shape this
# repo ships: "3.83.39" (pins.env), "3.83.26.0" (RaceStudio3.xmv), "v3.83.39-1" (release tag,
# build-apps.sh:44) and "3.83.39.1" (CFBundleVersion, build-apps.sh:295). The tag's "-<rev>" and
# the bundle's ".<rev>" are the same field, so both collapse to a separator.
_ver_fields() {
  local v="${1#v}"
  printf '%s' "${v//-/.}" | tr '.' ' '
}

# ver_cmp <a> <b> : print lt | eq | gt. Missing trailing fields count as zero, so 3.83.39 and
# 3.83.39.0 are equal. Returns 1 printing NOTHING when either side has a non-numeric field, so a
# caller can tell "older" apart from "unparseable" and refuse to guess.
ver_cmp() {
  local -a A B
  A=($(_ver_fields "$1")); B=($(_ver_fields "$2"))
  local n="${#A[@]}" i x y
  [ "${#B[@]}" -gt "$n" ] && n="${#B[@]}"
  [ "$n" -gt 0 ] || return 1
  for (( i = 0; i < n; i++ )); do
    x="${A[i]:-0}"; y="${B[i]:-0}"
    case "$x$y" in ''|*[!0-9]*) return 1 ;; esac
    x=$((10#$x)); y=$((10#$y))          # base-10: "08" is not octal here
    if [ "$x" -gt "$y" ]; then printf 'gt'; return 0; fi
    if [ "$x" -lt "$y" ]; then printf 'lt'; return 0; fi
  done
  printf 'eq'
}

# rs3_installed_ver [xmv_path] : print the RaceStudio 3 version AiM's installer recorded in its
# own manifest (default: the one inside our prefix). That file is the source of truth because AiM
# writes it — a marker of ours would go stale the moment RS3's in-app updater ran.
#
# The manifest is CRLF; the capture stops at '<' so the \r never reaches the value. Returns 1
# printing nothing when the file is absent, the tag is absent, or the value isn't a plausible
# version — callers must treat that as "unknown", never as "up to date".
rs3_installed_ver() {
  local xmv="${1:-$PREFIX/drive_c/$RS3_REL_XMV}" v
  [ -f "$xmv" ] || return 1
  v="$(sed -nE 's|.*<p n="VERSION">([^<]*)</p>.*|\1|p' "$xmv" 2>/dev/null | head -1)"
  [ -n "$v" ] || return 1
  printf '%s' "$v" | grep -Eq '^[0-9]+(\.[0-9]+){2,3}$' || return 1
  printf '%s' "$v"
}

# rs3_installed_at_least <want> : true when the installed RaceStudio 3 is >= <want>.
#
# ">=" and not "==" on purpose. If RS3's in-app updater has moved the user to 3.84.0 and our pin
# still says 3.83.39, equality would call the install unsatisfied and reinstall the older build
# over the newer one. ledger_skip_if_done returns a boolean, so it has no way to express "newer
# than expected" — ">=" is what makes "never downgrade a user automatically" actually true.
rs3_installed_at_least() {
  local have; have="$(rs3_installed_ver)" || return 1
  case "$(ver_cmp "$have" "$1")" in
    eq|gt) return 0 ;;
    *)     return 1 ;;
  esac
}
```

- [ ] **Step 6: Run the test and confirm it passes**

Run: `bash installer/test/unit-version.sh`
Expected: `unit-version: <n> passed, 0 failed` — every assertion passes, none fail.

- [ ] **Step 7: Mutation check**

Prove the tests bite. Apply each mutation, run the test, confirm the named assertion fails, then restore the file exactly (`git checkout -- installer/src/lib/wine.sh` between mutations — do not hand-revert).

1. In `rs3_installed_at_least`, change `eq|gt)` to `gt)`. Expected: `FAIL equal version is satisfied`.
2. ~~In `ver_cmp`, delete the `x=$((10#$x)); y=$((10#$y))` line.~~ **Retired — this mutation does not
   bite, verified on bash 3.2.57.** `[ 08 -gt 7 ]` is true; only `$(( ))` treats a leading zero as
   octal, and the `10#` line is the only thing that feeds a field to `$(( ))`. The line stays as
   defence against a future refactor to `(( ))`, but the `leading zero compares base-10` assertion
   passes with or without it, so it is not load-bearing. Do not delete the line and do not expect
   this mutation to fail.
3. In `rs3_installed_ver`, delete the `grep -Eq` validation line. Expected: `FAIL non-version value is refused`.

- [ ] **Step 8: Register the test**

In `installer/test/run-all.sh:7`, add `unit-version.sh` to the `TESTS` array immediately after `unit-validators.sh`.

Run: `bash installer/test/run-all.sh`
Expected: `ALL TESTS PASSED`, 16 files run.

- [ ] **Step 9: Commit**

Invoke the `commit-and-verify` skill with this message:

```
feat(installer): read the installed RS3 version from AiM's manifest (plan task 1)

Adds ver_cmp + rs3_installed_ver + rs3_installed_at_least and a real captured
RaceStudio3.xmv fixture. Nothing uses them yet.
```

---

### Task 2: Diagnostics report the installed version, not the pinned one

**Files:**
- Modify: `installer/src/collect-logs.sh:57-60`
- Modify: `installer/test/unit-collect-logs.sh`

**Interfaces:**
- Consumes: nothing from Task 1 at runtime. `collect-logs.sh` embeds no `lib/` (`build-apps.sh:326-331`), so it carries its own copy of the one-line parse. The duplication is deliberate and both copies are covered by the same fixture.
- Produces: two lines in `system-info.txt` — `RS3 version (installed):` and `RS3 version (pinned):`.

- [ ] **Step 1: Write the failing test**

Add to `installer/test/unit-collect-logs.sh`, immediately before the final `finish`:

```bash
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
```

- [ ] **Step 2: Run it and confirm it fails**

Run: `bash installer/test/unit-collect-logs.sh`
Expected: FAIL on `reports the INSTALLED version` (the current output line reads `RS3 version: 3.83.39`).

- [ ] **Step 3: Implement**

Replace `installer/src/collect-logs.sh:57-60` (the `if [ -f "$PINS" ]` block) with:

```bash
  # Report what is INSTALLED and what this app PINS as two separate facts. Reporting only the pin
  # (what this did before) made every support log claim the pinned version regardless of what the
  # user was actually running, which is exactly how the "a DMG upgrade doesn't update RS3" bug
  # stayed invisible. Parsed inline because this script embeds no lib/ (build-apps.sh:326-331);
  # lib/wine.sh::rs3_installed_ver is the same one-liner and the same fixture covers both.
  xmv="$INSTALL_ROOT/prefix/drive_c/AIM_SPORT/RaceStudio3/RaceStudio3.xmv"
  inst="$(sed -nE 's|.*<p n="VERSION">([^<]*)</p>.*|\1|p' "$xmv" 2>/dev/null | head -1)"
  echo "RS3 version (installed): ${inst:-unknown (no $xmv)}"
  if [ -f "$PINS" ]; then
    pinned="$(sed -nE 's/^RS3_PINNED_VER="(.*)"/\1/p' "$PINS")"
    echo "RS3 version (pinned):    $pinned"
    echo "pkg rev:     $(sed -nE 's/^RS3_PKG_REV="(.*)"/\1/p' "$PINS")"
    # A trailing ".0" is AiM's fourth field, not a different build, so don't cry mismatch over it.
    if [ -n "$inst" ] && [ -n "$pinned" ] && [ "${inst%.0}" != "$pinned" ]; then
      echo "  ^ installed differs from pinned — the upgrade never ran, or RS3 updated itself"
    fi
  fi
```

- [ ] **Step 4: Run the test and confirm it passes**

Run: `bash installer/test/unit-collect-logs.sh`
Expected: `0 failed`.

- [ ] **Step 5: Mutation check**

Change `${inst:-unknown (no $xmv)}` to `${inst:-$pinned}` and re-run.
Expected: `FAIL no manifest reports unknown, not the pin`. Restore with `git checkout -- installer/src/collect-logs.sh`.

- [ ] **Step 6: Commit**

Invoke `commit-and-verify`:

```
fix(logs): report the installed RS3 version, not the pinned one (plan task 2)

Diagnostics printed RS3_PINNED_VER, so every support log claimed the pinned
version whatever was installed. Now prints both and flags a mismatch.
```

---

### Task 3: A remembered or user-picked installer must be the pinned one

**Files:**
- Modify: `installer/src/lib/net.sh` (append after `download_verified`)
- Modify: `installer/src/installer-core.sh:144-192` (`phase_acquire_installer`)
- Modify: `installer/src/RaceStudio3.applescript:282-292`
- Modify: `installer/test/unit-net.sh` (append before `finish`)
- Create: `installer/test/unit-acquire.sh`
- Modify: `installer/test/run-all.sh:7`

**Interfaces:**
- Consumes: `file_size`, `sha256` (net.sh), `RS3_PINNED_FILE`/`_SIZE`/`_SHA256` (pins.env).
- Produces: `verify_local_asset <path> <want_name> <want_size> [want_sha]` → returns 0 only when the file exists, its basename matches, its size matches and (if given) its sha256 matches.
- Produces: `phase_acquire_installer` now emits `NEEDS_INSTALLER: <filename>` (was a bare `NEEDS_INSTALLER`); the applet parses the filename off that line.

- [ ] **Step 1: Write the failing unit test for the gate**

Append to `installer/test/unit-net.sh`, before `finish`:

```bash
# --- verify_local_asset -----------------------------------------------------------------------
# Every locally-sourced installer (a config.env path, a GUI-picked file, one found in ~/Downloads)
# must clear the same bar a download does: right name, right size, right bytes.
VLA="$SANDBOX/vla"; mkdir -p "$VLA"
GOOD="$VLA/RaceStudio3-64_39999_000000_000000_20260101_000000.exe"
printf 'payload' > "$GOOD"
GSIZE="$(file_size "$GOOD")"; GSHA="$(sha256 "$GOOD")"
GNAME="$(basename "$GOOD")"

assert_true  "verify_local_asset '$GOOD' '$GNAME' '$GSIZE' '$GSHA'" "accepts the real asset"
assert_true  "verify_local_asset '$GOOD' '$GNAME' '$GSIZE'"          "sha is optional"
assert_false "verify_local_asset '$VLA/absent.exe' '$GNAME' '$GSIZE' '$GSHA'" "rejects a missing file"

STALE="$VLA/RaceStudio3-64_38326_000000_000000_20260613_071826.exe"
printf 'payload' > "$STALE"
assert_false "verify_local_asset '$STALE' '$GNAME' '$GSIZE' '$GSHA'" \
  "rejects a stale basename even when the bytes match"

SHORT="$VLA/short/$GNAME"; mkdir -p "$VLA/short"; printf 'pay' > "$SHORT"
assert_false "verify_local_asset '$SHORT' '$GNAME' '$GSIZE' '$GSHA'" "rejects a truncated file"

TAMPER="$VLA/tamper/$GNAME"; mkdir -p "$VLA/tamper"; printf 'payloaD' > "$TAMPER"
assert_eq "$(file_size "$TAMPER")" "$GSIZE" "tampered file is the same size"
assert_false "verify_local_asset '$TAMPER' '$GNAME' '$GSIZE' '$GSHA'" \
  "rejects a same-name same-size file with different bytes"
```

- [ ] **Step 2: Run it and confirm it fails**

Run: `bash installer/test/unit-net.sh`
Expected: FAIL — `verify_local_asset: command not found`.

- [ ] **Step 3: Implement `verify_local_asset`**

Append to `installer/src/lib/net.sh`:

```bash
# verify_local_asset <path> <want_name> <want_size> [want_sha256]
# True only when the file on disk IS the asset we mean to install. Every path that produces an
# installer WITHOUT downloading it — a filename remembered in config.env, a file the user picked in
# the GUI, one found in ~/Downloads — goes through this, so none of them can smuggle in a different
# (or corrupt) build than download_verified would have accepted. Name is checked as well as bytes:
# a correct-looking file of the WRONG VERSION is the failure this exists to stop.
verify_local_asset() {
  local p="$1" name="$2" want_size="$3" want_sha="${4:-}"
  [ -f "$p" ] || return 1
  [ "$(basename "$p")" = "$name" ] || return 1
  [ "$(file_size "$p")" = "$want_size" ] || return 1
  [ -z "$want_sha" ] || [ "$(sha256 "$p")" = "$want_sha" ]
}
```

- [ ] **Step 4: Run the unit test and confirm it passes**

Run: `bash installer/test/unit-net.sh`
Expected: all assertions pass, `0 failed`.

- [ ] **Step 5: Write the failing phase test**

Create `installer/test/unit-acquire.sh`. It runs the REAL `phase_acquire_installer` against a copy of `src/` whose `pins.env` points at tiny local fixtures and at unroutable URLs, so it is hermetic — no network, no 350 MB.

```bash
#!/bin/bash
# unit-acquire.sh — phase_acquire_installer must accept a remembered installer only when it IS the
# pinned one. Before this, `[ -f "$pre" ]` meant a config.env left over from an older app kept
# pointing at the previous RaceStudio 3 and every DMG upgrade reinstalled the version it already
# had. Hermetic: src/ is copied, pins.env is rewritten to tiny fixtures, and both remote URLs point
# at a closed local port so every network path fails immediately.
_T_NAME="unit-acquire"
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
. "$HERE/harness.sh"

SRC="$SANDBOX/src"
ditto "$HERE/../src" "$SRC"

FILE="RaceStudio3-64_39999_000000_000000_20260101_000000.exe"
ASSET="$SANDBOX/$FILE"
printf 'pinned-installer-payload' > "$ASSET"
SIZE="$(file_size "$ASSET")"; SHA="$(sha256 "$ASSET")"
DEAD="https://127.0.0.1:1"       # connection refused, instantly

# Rewrite the pins the phase reads. Everything else in pins.env is left alone. BSD sed, so -i
# takes an explicit empty suffix. No python3 here on purpose: an end-user Mac has no Xcode CLT.
sed -i '' -E \
  -e "s|^RS3_PINNED_FILE=.*|RS3_PINNED_FILE=\"$FILE\"|" \
  -e "s|^RS3_PINNED_SIZE=.*|RS3_PINNED_SIZE=$SIZE|" \
  -e "s|^RS3_PINNED_SHA256=.*|RS3_PINNED_SHA256=\"$SHA\"|" \
  -e "s|^RS3_PINNED_URL=.*|RS3_PINNED_URL=\"$DEAD/$FILE\"|" \
  -e "s|^RS3_DOWNLOAD_PAGE=.*|RS3_DOWNLOAD_PAGE=\"$DEAD/page\"|" \
  "$SRC/pins.env"
grep -q "^RS3_PINNED_FILE=\"$FILE\"$" "$SRC/pins.env" || { echo "pins rewrite failed"; exit 2; }

ROOT="$SANDBOX/root"
CACHE="$ROOT/installer"
mkdir -p "$CACHE" "$ROOT/state"

run_acquire() {   # -> prints output, returns the phase's exit code
  ( cd "$SANDBOX" && HOME="$SANDBOX/fakehome" RS3_APP_SUPPORT="$ROOT" UI_MODE=applet \
      bash "$SRC/installer-core.sh" acquire-installer 2>&1 )
}
mkdir -p "$SANDBOX/fakehome/Downloads"

# --- case 1: remembered installer IS the pinned one -> accepted, no network ------------------
ditto "$ASSET" "$CACHE/$FILE"
printf 'INSTALLER_EXE=%q\n' "$CACHE/$FILE" > "$ROOT/state/config.env"
out="$(run_acquire)"; rc=$?
assert_true "[ $rc -eq 0 ]" "valid remembered installer: phase succeeds"
assert_true "printf '%s' \"\$out\" | grep -q 'Installer ready'" "valid remembered installer: accepted"

# --- case 2: remembered installer is a DIFFERENT (older) build -> rejected -------------------
STALE="RaceStudio3-64_38326_000000_000000_20260613_071826.exe"
ditto "$ASSET" "$CACHE/$STALE"
printf 'INSTALLER_EXE=%q\n' "$CACHE/$STALE" > "$ROOT/state/config.env"
out="$(run_acquire)"; rc=$?
assert_true "[ $rc -eq 10 ]" "stale basename: phase does NOT succeed (asks for the installer)"
assert_true "printf '%s' \"\$out\" | grep -q 'NEEDS_INSTALLER: $FILE'" \
  "stale basename: names the file it needs"

# --- case 3: right name, wrong size -> rejected ----------------------------------------------
BAD="$SANDBOX/badsize/$FILE"; mkdir -p "$SANDBOX/badsize"
printf 'short' > "$BAD"
printf 'INSTALLER_EXE=%q\n' "$BAD" > "$ROOT/state/config.env"
out="$(run_acquire)"; rc=$?
assert_true "[ $rc -eq 10 ]" "wrong size: phase does NOT succeed"

# --- case 4: the pinned installer is sitting in ~/Downloads -> used --------------------------
rm -f "$ROOT/state/config.env" "$CACHE/$FILE"
ditto "$ASSET" "$SANDBOX/fakehome/Downloads/$FILE"
out="$(run_acquire)"; rc=$?
assert_true "[ $rc -eq 0 ]" "pinned file in Downloads: phase succeeds"
assert_true "printf '%s' \"\$out\" | grep -q 'Downloads'" "pinned file in Downloads: used it"

# --- case 5: a DIFFERENT build in ~/Downloads -> not used ------------------------------------
rm -f "$ROOT/state/config.env" "$CACHE/$FILE" "$SANDBOX/fakehome/Downloads/$FILE"
ditto "$ASSET" "$SANDBOX/fakehome/Downloads/$STALE"
out="$(run_acquire)"; rc=$?
assert_true "[ $rc -eq 10 ]" "wrong build in Downloads: not accepted"

finish
```

- [ ] **Step 6: Run it and confirm it fails**

Run: `bash installer/test/unit-acquire.sh`
Expected: FAIL on `stale basename: phase does NOT succeed` — today the phase accepts any existing file and returns 0.

- [ ] **Step 7: Implement the acquire gate**

In `installer/src/installer-core.sh`, replace lines 146-148 (the recall short-circuit) and lines 174-183 (the Downloads fallback).

Recall short-circuit — replace:

```bash
  # Already have a usable installer (verified earlier, or one the user picked via the GUI)?
  local pre; pre="$(ui_recall INSTALLER_EXE || true)"
  if [ -n "$pre" ] && [ -f "$pre" ] && [ "$DRY_RUN" != 1 ]; then ui_say "Installer ready."; return 0; fi
  local want="$INSTALLER_CACHE/$RS3_PINNED_FILE"
  validate_rs3_asset "$RS3_PINNED_FILE" || die "internal: bad pinned RS3 filename"
```

with:

```bash
  local want="$INSTALLER_CACHE/$RS3_PINNED_FILE"
  validate_rs3_asset "$RS3_PINNED_FILE" || die "internal: bad pinned RS3 filename"

  # A remembered installer counts only if it IS the pinned one. This used to be `[ -f "$pre" ]`,
  # which meant a config.env written by an older version of this app kept pointing at the previous
  # RaceStudio 3 — so installing a newer DMG downloaded nothing, installed nothing, and left the
  # user on the old build while the CHANGELOG claimed otherwise. The size+sha check also covers the
  # GUI "choose file" path (RaceStudio3.applescript), which copies whatever the user picks.
  local pre; pre="$(ui_recall INSTALLER_EXE || true)"
  if [ -n "$pre" ] && [ "$DRY_RUN" != 1 ]; then
    if verify_local_asset "$pre" "$RS3_PINNED_FILE" "$RS3_PINNED_SIZE" "$RS3_PINNED_SHA256"; then
      ui_say "Installer ready."; return 0
    fi
    log "ignoring remembered installer (wrong name, size or sha): $pre"
  fi
```

Downloads fallback — replace:

```bash
  # Fallback 2: a matching file already in ~/Downloads (size match preferred).
  local d
  for d in "$HOME/Downloads"/RaceStudio3-64_*.exe; do
    [ -e "$d" ] || continue
    if [ "$(file_size "$d")" = "$RS3_PINNED_SIZE" ]; then
      ditto "$d" "$want"; ui_persist INSTALLER_EXE "$want"
      ui_say "Using the installer you already have in Downloads."
      return 0
    fi
  done
```

with:

```bash
  # Fallback 2: the pinned installer already sitting in ~/Downloads. Name AND bytes must match —
  # the old size-only check on a `RaceStudio3-64_*.exe` glob would happily install a different
  # build that happened to be the same length.
  local d="$HOME/Downloads/$RS3_PINNED_FILE"
  if verify_local_asset "$d" "$RS3_PINNED_FILE" "$RS3_PINNED_SIZE" "$RS3_PINNED_SHA256"; then
    ditto "$d" "$want"; ui_persist INSTALLER_EXE "$want"
    ui_say "Using the installer you already have in Downloads."
    return 0
  fi
```

Fallback 3 — change the applet signal at line 187 from `printf 'NEEDS_INSTALLER\n'` to:

```bash
    printf 'NEEDS_INSTALLER: %s\n' "$RS3_PINNED_FILE"; exit "$SIG_NEEDS"
```

- [ ] **Step 8: Run the phase test and confirm it passes**

Run: `bash installer/test/unit-acquire.sh`
Expected: `unit-acquire: 8 passed, 0 failed` (all five cases).

- [ ] **Step 9: Tell the user which file to pick**

Without this, a user who picks the wrong file gets the same picker again with no explanation, forever (`runPhase` loops unbounded). In `installer/src/RaceStudio3.applescript`, replace lines 282-287:

```applescript
	else if out contains "NEEDS_INSTALLER" then
		display dialog "I couldn't download the RaceStudio 3 installer automatically. I'll open AiM's download page — save the installer, then choose it on the next screen." buttons {"Open AiM page"} default button 1 with title "Get the installer" with icon note
		try
			do shell script "open 'https://www.aim-sportline.com/docs/racestudio3/html/release/download-release.html'"
		end try
		set f to choose file with prompt "Select the RaceStudio3 installer you downloaded (RaceStudio3-64_….exe)"
```

with:

```applescript
	else if out contains "NEEDS_INSTALLER" then
		-- The core names the exact file it needs. Say it out loud: the file is now checked, so
		-- picking the wrong one just brings this dialog back, and a user who isn't told which
		-- file to pick has no way out of that loop.
		set wantFile to ""
		try
			set wantFile to do shell script "printf '%s' " & quoted form of out & " | sed -n 's/^NEEDS_INSTALLER: //p' | head -1"
		end try
		if wantFile is "" then set wantFile to "RaceStudio3-64_….exe"
		display dialog "I couldn't download the RaceStudio 3 installer automatically. I'll open AiM's download page — save “" & wantFile & "”, then choose it on the next screen." buttons {"Open AiM page"} default button 1 with title "Get the installer" with icon note
		try
			do shell script "open 'https://www.aim-sportline.com/docs/racestudio3/html/release/download-release.html'"
		end try
		set f to choose file with prompt "Select “" & wantFile & "”"
```

- [ ] **Step 10: Verify the applet still compiles**

Run: `osacompile -o "$TMPDIR/acquire-check.app" installer/src/RaceStudio3.applescript && echo COMPILES`
Expected: `COMPILES`, no output from osacompile. Then `rm -rf "$TMPDIR/acquire-check.app"`.

- [ ] **Step 11: Mutation check**

In `phase_acquire_installer`, change `verify_local_asset "$pre" "$RS3_PINNED_FILE" "$RS3_PINNED_SIZE" "$RS3_PINNED_SHA256"` to `[ -f "$pre" ]` (the old behaviour) and run `bash installer/test/unit-acquire.sh`.
Expected: `FAIL stale basename: phase does NOT succeed`. Restore with `git checkout -- installer/src/installer-core.sh`.

- [ ] **Step 12: Register the test and run everything**

Add `unit-acquire.sh` to `TESTS` in `installer/test/run-all.sh:7`, after `unit-net.sh`.

Run: `bash installer/test/run-all.sh`
Expected: `ALL TESTS PASSED`, 17 files.

- [ ] **Step 13: Commit**

Invoke `commit-and-verify`:

```
fix(installer): only reuse an installer that is the pinned one (plan task 3)

phase_acquire_installer trusted any file config.env pointed at, so a DMG upgrade
kept reinstalling the previous RaceStudio 3. Remembered, GUI-picked and
~/Downloads installers now all clear the same name+size+sha gate a download does.
```

---

### Task 4: `installed` means the pinned version is installed

**Files:**
- Modify: `installer/src/lib/ledger.sh:23-25`
- Modify: `installer/test/unit-ledger.sh`

**Interfaces:**
- Consumes: `rs3_installed_at_least` (Task 1), `RS3_PINNED_VER` (pins.env).
- Produces: `ledger_verify installed` is now false for an older RS3, which is what makes `phase_silent_install` stop skipping (`installer-core.sh:253`) and what `--repair` keys off (`installer-core.sh:429-431`).

- [ ] **Step 1: Write the failing test**

In `installer/test/unit-ledger.sh`, replace the `REFEXE` block (lines 17-22) with:

```bash
# Use a real PE32+ binary if the reference prefix has one
REFEXE="$HOME/.rs3-w11-test/drive_c/$RS3_REL_EXE"
if [ -f "$REFEXE" ]; then
  ditto "$REFEXE" "$PREFIX/drive_c/$RS3_REL_EXE"
  # A valid PE is no longer enough: the version AiM recorded must be >= the pin, or an upgrade
  # would see "already installed" and skip the install that IS the upgrade.
  mkdir -p "$PREFIX/drive_c/$(dirname "$RS3_REL_XMV")"
  ditto "$(dirname "${BASH_SOURCE[0]}")/fixtures/RaceStudio3-3.83.26.xmv" "$PREFIX/drive_c/$RS3_REL_XMV"
  assert_false "ledger_verify installed" "installed: real exe but OLDER version is not satisfied"

  printf '<p n="VERSION">%s</p>\r\n' "$RS3_PINNED_VER" > "$PREFIX/drive_c/$RS3_REL_XMV"
  assert_true  "ledger_verify installed" "installed: real exe at the pinned version is satisfied"

  printf '<p n="VERSION">99.0.0</p>\r\n' > "$PREFIX/drive_c/$RS3_REL_XMV"
  assert_true  "ledger_verify installed" "installed: a NEWER version is satisfied (never downgrade)"

  rm -f "$PREFIX/drive_c/$RS3_REL_XMV"
  assert_false "ledger_verify installed" "installed: unknown version is not satisfied"
fi
```

- [ ] **Step 2: Run it and confirm it fails**

Run: `bash installer/test/unit-ledger.sh`

Expected: if `$HOME/.rs3-w11-test/drive_c/…` exists, FAIL on `installed: real exe but OLDER version is not satisfied`. **If that reference prefix does not exist the block is skipped and the test passes vacuously** — in that case create the PE from the live install first and re-run:

```bash
mkdir -p "$HOME/.rs3-w11-test/drive_c/AIM_SPORT/RaceStudio3/64"
ditto "$HOME/Library/Application Support/RaceStudio3/prefix/drive_c/AIM_SPORT/RaceStudio3/64/AiMRS3-64-ReleaseU.exe" \
      "$HOME/.rs3-w11-test/drive_c/AIM_SPORT/RaceStudio3/64/AiMRS3-64-ReleaseU.exe"
```

Do not proceed until you have seen this test fail for the right reason.

- [ ] **Step 3: Implement**

In `installer/src/lib/ledger.sh`, replace the `installed)` case:

```bash
    installed)
      # Structural AND version. The old check was "the exe exists and is a PE32+", which is true
      # of any RaceStudio 3 — so after a DMG upgrade phase_silent_install saw the marker satisfied,
      # skipped, and left the user on the old build. ">=" not "==": if RS3's own updater has moved
      # the user ahead of our pin, that is satisfied too, so nothing here downgrades anyone.
      # An unreadable version counts as NOT satisfied — reinstalling the pinned build over an
      # unknown one is safe (user data lives outside the prefix, symlinked to $DATA_DIR).
      [ -f "$PREFIX/drive_c/$RS3_REL_EXE" ] \
        && file "$PREFIX/drive_c/$RS3_REL_EXE" | grep -q 'PE32+ executable' \
        && rs3_installed_at_least "$RS3_PINNED_VER" ;;
```

- [ ] **Step 4: Run the test and confirm it passes**

Run: `bash installer/test/unit-ledger.sh`
Expected: `0 failed`. The four new assertions only run when the reference prefix from Step 2 exists.

- [ ] **Step 5: Mutation check**

Delete the `&& rs3_installed_at_least "$RS3_PINNED_VER"` line and re-run.
Expected: `FAIL installed: real exe but OLDER version is not satisfied`. Restore with `git checkout -- installer/src/lib/ledger.sh`.

- [ ] **Step 6: Full suite**

Run: `bash installer/test/run-all.sh`
Expected: `ALL TESTS PASSED`. `dryrun-test.sh` exercises the phases with `DRY_RUN=1`; if it now fails, the dry-run path is reaching the version check with no prefix — fix by leaving the dry-run early-returns exactly where they are, not by weakening the check.

- [ ] **Step 7: Commit**

Invoke `commit-and-verify`:

```
fix(installer): 'installed' now means the pinned RS3 version is installed (plan task 4)

The postcondition only checked for a PE32+ exe, so silent-install skipped on an
upgrade. Now requires installed >= pinned, so a newer RS3 (in-app updater) still
counts and is never downgraded.
```

---

### Task 5: `--reinstall` must not reinstall the old version

**Files:**
- Modify: `installer/src/lib/ui.sh` (append after `ui_recall`)
- Modify: `installer/src/lib/ledger.sh` (append at end)
- Modify: `installer/src/installer-core.sh:435-442` (`do_reinstall`)
- Modify: `installer/test/harness.sh:20-27`
- Modify: `installer/test/unit-ledger.sh`

**Interfaces:**
- Consumes: `CONFIG_ENV`, `STATE_DIR`, `INSTALLER_CACHE`.
- Produces: `ui_forget <key>` → removes one key from config.env, returns 0. `ledger_reset_for_reinstall` → clears every `.ok` marker, forgets `INSTALLER_EXE`, deletes cached `RaceStudio3-64_*.exe`.

- [ ] **Step 1: Give the harness an installer cache**

In `installer/test/harness.sh`, after the `CONFIG_ENV=` line add:

```bash
INSTALLER_CACHE="$INSTALL_ROOT/installer"
```

and add `"$INSTALLER_CACHE"` to the existing `mkdir -p "$STATE_DIR"` line.

- [ ] **Step 2: Write the failing test**

Append to `installer/test/unit-ledger.sh`, before `finish`:

```bash
# --- ui_forget --------------------------------------------------------------------------------
ui_persist DATA_DIR "$DATA_DIR"
ui_persist INSTALLER_EXE "/some/old/RaceStudio3-64_38326_000000_000000_20260613_071826.exe"
assert_eq "$(ui_recall INSTALLER_EXE)" "/some/old/RaceStudio3-64_38326_000000_000000_20260613_071826.exe" "persisted"
ui_forget INSTALLER_EXE
assert_false "ui_recall INSTALLER_EXE" "ui_forget drops the key"
assert_eq "$(ui_recall DATA_DIR)" "$DATA_DIR" "ui_forget keeps every OTHER key"

# --- ledger_reset_for_reinstall -----------------------------------------------------------------
# A reinstall that keeps the remembered installer and the cached exe reinstalls exactly the version
# the user is trying to get off.
ledger_mark installed; ledger_mark wine
ui_persist INSTALLER_EXE "$INSTALLER_CACHE/RaceStudio3-64_38326_000000_000000_20260613_071826.exe"
: > "$INSTALLER_CACHE/RaceStudio3-64_38326_000000_000000_20260613_071826.exe"
: > "$INSTALLER_CACHE/wine-staging-11.9-osx64.tar.xz"

ledger_reset_for_reinstall

assert_false "ledger_has installed" "reset: cleared the installed marker"
assert_false "ledger_has wine"      "reset: cleared the wine marker"
assert_false "ui_recall INSTALLER_EXE" "reset: forgot the remembered installer"
assert_absent "$INSTALLER_CACHE/RaceStudio3-64_38326_000000_000000_20260613_071826.exe"
assert_file   "$INSTALLER_CACHE/wine-staging-11.9-osx64.tar.xz"
assert_eq "$(ui_recall DATA_DIR)" "$DATA_DIR" "reset: kept the user's chosen data folder"
```

- [ ] **Step 3: Run it and confirm it fails**

Run: `bash installer/test/unit-ledger.sh`
Expected: FAIL — `ui_forget: command not found`.

- [ ] **Step 4: Implement `ui_forget`**

Append to `installer/src/lib/ui.sh` after `ui_recall`:

```bash
# ui_forget <key> : drop one persisted decision, leaving the rest of config.env alone. Used by
# --reinstall, which must not inherit a stale INSTALLER_EXE — and which must NOT just delete
# config.env, because that file also holds DATA_DIR. Losing that would point a reinstall at the
# default data folder and strand the user's telemetry in the one they chose.
ui_forget() {
  local key="$1" tmp
  [ -n "${CONFIG_ENV:-}" ] && [ -f "$CONFIG_ENV" ] || return 0
  tmp="$CONFIG_ENV.tmp.$$"
  grep -v "^${key}=" "$CONFIG_ENV" > "$tmp" 2>/dev/null || true
  mv -f "$tmp" "$CONFIG_ENV"
}
```

- [ ] **Step 5: Implement `ledger_reset_for_reinstall`**

Append to `installer/src/lib/ledger.sh`:

```bash
# ledger_reset_for_reinstall : put the ledger back to "nothing done" for --reinstall.
#
# Clearing the markers alone was not enough: the remembered INSTALLER_EXE and the cached exe both
# survived, so "reinstall" faithfully reinstalled the same old RaceStudio 3. Keeps the rest of
# config.env (DATA_DIR above all) and keeps the Wine tarball, which is sha-verified on reuse —
# no reason to make every reinstall re-download 190 MB.
ledger_reset_for_reinstall() {
  rm -f "$STATE_DIR"/*.ok 2>/dev/null || true
  ui_forget INSTALLER_EXE
  rm -f "$INSTALLER_CACHE"/RaceStudio3-64_*.exe 2>/dev/null || true
}
```

- [ ] **Step 6: Call it from `do_reinstall`**

In `installer/src/installer-core.sh`, replace:

```bash
  wineserver_kill 2>/dev/null || true
  rm -rf "$WINE_ROOT" "$PREFIX" "$STATE_DIR"/*.ok 2>/dev/null || true
  WINE_BIN=""
```

with:

```bash
  wineserver_kill 2>/dev/null || true
  rm -rf "$WINE_ROOT" "$PREFIX" 2>/dev/null || true
  ledger_reset_for_reinstall
  WINE_BIN=""
```

- [ ] **Step 7: Run the test and confirm it passes**

Run: `bash installer/test/unit-ledger.sh`
Expected: `0 failed`.

- [ ] **Step 8: Mutation check**

Comment out the `ui_forget INSTALLER_EXE` line in `ledger_reset_for_reinstall` and re-run.
Expected: `FAIL reset: forgot the remembered installer`. Restore with `git checkout -- installer/src/lib/ledger.sh`.

- [ ] **Step 9: Commit**

Invoke `commit-and-verify`:

```
fix(installer): --reinstall no longer reinstalls the old RS3 (plan task 5)

do_reinstall cleared the .ok markers but kept config.env's INSTALLER_EXE and the
cached exe. Adds ui_forget + ledger_reset_for_reinstall; DATA_DIR and the
sha-verified Wine tarball are deliberately kept.
```

---

### Task 6: The app knows the difference between "not installed" and "out of date"

**Files:**
- Modify: `installer/src/installer-core.sh:516` and the dispatch `case`
- Modify: `installer/src/RaceStudio3.applescript:16-23`, `35`, `47-66`, `189-196`
- Modify: `installer/test/unit-acquire.sh` (append — it already builds a sandboxed src copy)

**Interfaces:**
- Consumes: `ledger_verify installed` (Task 4).
- Produces: `installer-core.sh install-state` prints exactly one of `RS3_INSTALLED`, `RS3_OUTDATED`, `RS3_ABSENT`.

- [ ] **Step 1: Write the failing test**

Append to `installer/test/unit-acquire.sh`, before `finish`:

```bash
# --- install-state ------------------------------------------------------------------------------
# The launcher needs three states, not two: a prefix holding an OLDER RaceStudio 3 is neither
# "ready to launch" nor "never set up", and telling an upgrading user "the first time you open it…"
# is wrong.
state_of() { ( cd "$SANDBOX" && HOME="$SANDBOX/fakehome" RS3_APP_SUPPORT="$ROOT" UI_MODE=applet \
                 bash "$SRC/installer-core.sh" install-state 2>/dev/null ); }

assert_eq "$(state_of)" "RS3_ABSENT" "no prefix at all: absent"

mkdir -p "$ROOT/prefix/drive_c/AIM_SPORT/RaceStudio3/64" "$ROOT/bin"
: > "$ROOT/bin/launch.sh"; chmod +x "$ROOT/bin/launch.sh"
: > "$ROOT/prefix/drive_c/AIM_SPORT/RaceStudio3/64/AiMRS3-64-ReleaseU.exe"
assert_eq "$(state_of)" "RS3_OUTDATED" "RS3 present but not at the pinned version: outdated"
```

(The exe here is not a real PE, so `ledger_verify installed` is false for the structural reason — which is exactly the state an upgrade is in from the launcher's point of view. `RS3_INSTALLED` is covered by the on-device scenario in Task 7, not by a unit test, because it needs a real PE and a real manifest.)

- [ ] **Step 2: Run it and confirm it fails**

Run: `bash installer/test/unit-acquire.sh`
Expected: FAIL — `unknown action: install-state`.

- [ ] **Step 3: Implement the action**

In `installer/src/installer-core.sh`, add to the dispatch `case`, directly after the `is-installed)` line:

```bash
  install-state)
    # Three states, because "not launchable" has two very different causes and the app says a
    # different thing for each. OUTDATED = a RaceStudio 3 is there but not the one this app ships,
    # so the install phases need to run again (they no-op for everything already done).
    if ledger_verify installed && [ -x "$INSTALL_ROOT/bin/launch.sh" ]; then echo RS3_INSTALLED
    elif [ -f "$PREFIX/drive_c/$RS3_REL_EXE" ] && [ -x "$INSTALL_ROOT/bin/launch.sh" ]; then echo RS3_OUTDATED
    else echo RS3_ABSENT; fi ;;
```

Leave `is-installed` exactly as it is.

- [ ] **Step 4: Run the test and confirm it passes**

Run: `bash installer/test/unit-acquire.sh`
Expected: `0 failed`.

- [ ] **Step 5: Teach the app the third state**

In `installer/src/RaceStudio3.applescript`, replace the `on run` handler (lines 16-23):

```applescript
on run
	set coreScript to corePath()
	set st to installState(coreScript)
	if st is "RS3_INSTALLED" then
		openApp()
	else if st is "RS3_OUTDATED" then
		doUpdateSetup(coreScript)
	else
		doFirstRunSetup(coreScript)
	end if
end run
```

Replace `isInstalled` (lines 189-196) with both helpers:

```applescript
on installState(coreScript)
	try
		set out to do shell script "UI_MODE=applet " & quoted form of coreScript & " install-state 2>/dev/null"
		if out contains "RS3_INSTALLED" then return "RS3_INSTALLED"
		if out contains "RS3_OUTDATED" then return "RS3_OUTDATED"
		return "RS3_ABSENT"
	on error
		return "RS3_ABSENT"
	end try
end installState

-- Drag-and-drop import only needs a set-up prefix; importing into an older RaceStudio 3 is fine,
-- so an upgrade is deliberately NOT forced here.
on isInstalled(coreScript)
	return (installState(coreScript) is not "RS3_ABSENT")
end isInstalled
```

Extract the phase loop out of `doFirstRunSetup` so both flows share it. Replace lines 47-66 with:

```applescript
on doFirstRunSetup(coreScript)
	set b to button returned of (display dialog "Welcome to RaceStudio 3 for Mac." & return & return & "The first time you open it, I'll set everything up — no Windows, no Parallels." & return & return & "• Takes about 10 minutes and needs an internet connection." & return & "• Your data goes in your Documents folder." & return & "• Connect AiM devices over Wi-Fi (USB isn't supported)." buttons {"Quit", "Set Up"} default button "Set Up" with title "RaceStudio 3" with icon note)
	if b is "Quit" then return

	runAllPhases(coreScript)

	set b to button returned of (display dialog "RaceStudio 3 is ready! 🎉" & return & return & "• It's in your Applications folder for next time." & return & "• “Import RaceStudio 3 Data” and “Uninstall RaceStudio 3” are in Applications ▸ AiM." & return & "• Connect AiM devices over Wi-Fi (USB isn't supported under Wine)." & return & "• If macOS asks “Wine wants to access Documents”, click Allow." buttons {"Done", "Open RaceStudio 3"} default button "Open RaceStudio 3" with title "All set" with icon note)
	if b is "Open RaceStudio 3" then openApp()
end doFirstRunSetup

-- This app ships a newer RaceStudio 3 than the one already set up. Same phases as a first run —
-- everything already done verifies and skips — but the copy has to say "update", not "welcome",
-- and it has to be honest that it's a full download.
on doUpdateSetup(coreScript)
	set b to button returned of (display dialog "This version of the app installs a newer RaceStudio 3." & return & return & "• It downloads about 350 MB and takes several minutes." & return & "• Your settings and telemetry are not touched." & return & "• Quit RaceStudio 3 first if it's open." buttons {"Not Now", "Update"} default button "Update" with title "Update RaceStudio 3" with icon note)
	if b is "Not Now" then
		openApp()
		return
	end if

	runAllPhases(coreScript)

	set b to button returned of (display dialog "RaceStudio 3 is up to date." buttons {"Done", "Open RaceStudio 3"} default button "Open RaceStudio 3" with title "Update complete" with icon note)
	if b is "Open RaceStudio 3" then openApp()
end doUpdateSetup

on runAllPhases(coreScript)
	set total to count of phaseList
	set progress total steps to barScale
	set progress additional description to "0% complete"
	repeat with i from 1 to total
		set progress description to "Step " & i & " of " & total & ": " & (item i of phaseLabel) & "…"
		runPhase(coreScript, item i of phaseList, item i of phaseTimeout, i, total)
	end repeat
	set progress completed steps to barScale
	set progress additional description to "100% complete"
end runAllPhases
```

Note "Not Now" launches the old RaceStudio 3 rather than doing nothing — refusing an update must not leave the user unable to open the app.

- [ ] **Step 6: Verify the applet compiles**

Run: `osacompile -o "$TMPDIR/state-check.app" installer/src/RaceStudio3.applescript && echo COMPILES`
Expected: `COMPILES`. Then `rm -rf "$TMPDIR/state-check.app"`.

- [ ] **Step 7: Full suite**

Run: `bash installer/test/run-all.sh`
Expected: `ALL TESTS PASSED`, 17 files.

- [ ] **Step 8: Commit**

Invoke `commit-and-verify`:

```
feat(app): run the update flow when the app ships a newer RS3 (plan task 6)

Adds `install-state` (RS3_INSTALLED / RS3_OUTDATED / RS3_ABSENT) and an update
dialog, so upgrading users stop seeing the first-run welcome. "Not Now" still
opens the RaceStudio 3 they have.
```

---

### Task 7: Prove it on the device, then document and version it

**Files:**
- Modify: `installer/test/scenarios.md`
- Modify: `installer/src/pins.env:23` (`RS3_PKG_REV`)
- Modify: `CHANGELOG.md`

- [ ] **Step 1: Verify the whole suite from a clean tree**

Run:

```bash
git status --short
bash installer/test/run-all.sh
```

Expected: only intended files modified (plus the pre-existing `installer/build/pkg-scripts/postinstall` mode change, which is deliberately left alone), and `ALL TESTS PASSED`.

- [ ] **Step 2: Verify the real bug is gone on this Mac**

This Mac is the reproduction: the prefix holds 3.83.26.0 while `pins.env` pins 3.83.39. Confirm the engine now agrees, without installing anything:

```bash
bash -c '
  cd installer/src
  . ./pins.env
  for m in ui net wine ledger data preflight; do . "lib/$m.sh"; done
  INSTALL_ROOT="$HOME/Library/Application Support/RaceStudio3"
  PREFIX="$INSTALL_ROOT/prefix"; STATE_DIR="$INSTALL_ROOT/state"
  echo "installed: $(rs3_installed_ver)"
  echo "pinned:    $RS3_PINNED_VER"
  if ledger_verify installed; then echo "ledger: SATISFIED (wrong)"; else echo "ledger: NOT satisfied (correct)"; fi
'
```

Expected:

```
installed: 3.83.26.0
pinned:    3.83.39
ledger: NOT satisfied (correct)
```

Record the actual output in the commit body. If `ledger` says SATISFIED, stop — Task 4 is not working.

- [ ] **Step 3: Add the manual scenario**

Append to `installer/test/scenarios.md`, after the "Manual — migrating user" section:

```markdown
## Manual — upgrading to a DMG that ships a newer RaceStudio 3
1. Start from a Mac with an older RS3 installed (check with
   `sed -n 's|.*<p n="VERSION">\(.*\)</p>.*|\1|p' ~/Library/Application\ Support/RaceStudio3/prefix/drive_c/AIM_SPORT/RaceStudio3/RaceStudio3.xmv`).
2. Quit RaceStudio 3. Install the newer DMG over the top (drag, replace).
3. Launch `RaceStudio 3.app`. Expect the **"This version of the app installs a newer RaceStudio 3"**
   dialog — NOT the first-run welcome, and NOT a straight launch of the old version.
4. Click Update. Expect a real ~350 MB download, then the RS3 install, then "RaceStudio 3 is up to date."
5. Re-run the command from step 1: it must now report the version in `pins.env`.
6. Open "Show RaceStudio 3 Logs" and confirm `system-info.txt` reports `RS3 version (installed):`
   matching `RS3 version (pinned):` with no mismatch warning.
7. Confirm the data folder is untouched: sessions and configs are all still listed in RS3.
8. Launch the app once more — it must go straight to RaceStudio 3 with no dialog.
```

- [ ] **Step 4: Bump the packaging revision**

In `installer/src/pins.env`, set `RS3_PKG_REV="2"` (same upstream 3.83.39, re-released with this fix).

- [ ] **Step 5: Add the changelog entry**

Insert into `CHANGELOG.md` directly above the `## [3.83.39-1]` heading:

```markdown
## [3.83.39-2] — 2026-08-01

**Installing a newer version of this app now actually updates RaceStudio 3.**

- **Upgrades update RaceStudio 3.** Until now, installing a newer DMG over an existing setup left
  the old RaceStudio 3 in place: the installer remembered the file it had downloaded before and
  never noticed it was for a different version. If you installed 3.83.39-1 over an older setup, you
  were still running the older RaceStudio 3. Open the app once after updating and it offers to
  bring RaceStudio 3 up to date.
- **The app now tells you when an update is waiting** instead of showing the first-run welcome, and
  "Not Now" still opens the RaceStudio 3 you already have.
- **RaceStudio 3 is never downgraded.** If RaceStudio 3's own updater has moved you ahead of the
  version this app ships, that is left alone.
- **Diagnostics report the version you are actually running.** "Show RaceStudio 3 Logs" printed the
  version this app expected, not the one installed — which is why this went unnoticed. It now
  reports both and says so when they differ.
- **"Reinstall" reinstalls the current version**, instead of putting back the one it had cached.
- An installer supplied by hand (picked in the file dialog, or found in your Downloads folder) is
  now checked against the exact file this app expects before it is used.
```

- [ ] **Step 6: Final full verification**

Run:

```bash
bash installer/test/run-all.sh
bash -n installer/src/installer-core.sh installer/src/collect-logs.sh installer/src/lib/*.sh
osacompile -o "$TMPDIR/final-check.app" installer/src/RaceStudio3.applescript && echo COMPILES && rm -rf "$TMPDIR/final-check.app"
```

Expected: `ALL TESTS PASSED`, no syntax output, `COMPILES`.

- [ ] **Step 7: Commit**

Invoke `commit-and-verify`:

```
docs: changelog + upgrade scenario for the DMG-upgrade fix (plan task 7)

Bumps RS3_PKG_REV to 2 (same upstream 3.83.39, re-released with the upgrade fix).
Verified on device: prefix reports 3.83.26.0 against a 3.83.39 pin and the
ledger now correctly reports the install as unsatisfied.
```

- [ ] **Step 8: Ship it**

Open a PR (not a direct push to `main`). The bot-review loop applies: CI green **and** CodeRabbit `APPROVED` on the HEAD SHA before merge. The release tag `v3.83.39-2` is cut **after** merge and triggers `release-dmg.yml`; do not tag from the branch.

---

## Out of scope (Part B, blocked on nothing now but planned separately)

Channels (`pinned` / `latest`), the `latest.json` release asset, a standalone updater app, and
quitting a running RaceStudio 3 to update it. Both open decisions are now answered in the spec —
Part B gets its own plan after Part A merges.

In Part A, an upgrade with RaceStudio 3 already running stops at
`installer-core.sh:129-131` with "RaceStudio 3 is already running. Please quit it, then run the
installer again." That is the intended Part A behaviour: nothing here kills a live session.
