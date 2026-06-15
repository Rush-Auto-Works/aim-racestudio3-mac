# Show Logs app + native menu item — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add a one-click "Show Logs" app that gathers the current RaceStudio 3 logs into a Desktop folder and reveals it in Finder, surface it as a native macOS app-menu item, and make the `aim-bridge` daemon's output persist so it's actually collectable.

**Architecture:** A standalone AppleScript app (`Show RaceStudio 3 Logs.app`) in `/Applications/AiM`, peer to the existing Import/Uninstall apps, runs an embedded `collect-logs.sh` that copies present logs + a generated `system-info.txt` into `~/Desktop/AiM-Logs-<ts>/` and `open`s it. The `aim-bridge` LaunchDaemon plist gains `StandardErrorPath`/`StandardOutPath` so its stderr lands in `/Library/Logs/aim-bridge.log`. The native menu item reuses PR #14's `wine_rs3OpenAuxApp:` helper.

**Tech Stack:** bash (collect-logs.sh), AppleScript/osacompile (app wrapper), `installer/build/build-apps.sh` (bundling), the repo's bash test harness (`installer/test/harness.sh`), Objective-C/Cocoa patch (`winemac.drv`, only Task 5).

**Prerequisite:** Deliverable 1 (PR #14, `docs/plans/2026-06-07-native-menu-items.md`, Tasks 0–6) must be implemented first — it creates `installer/wine-patch/winemac-native-menu.patch` and the `wine_rs3OpenAuxApp:` helper that Task 5 below extends. Tasks 1–4 here are independent of PR #14 and can proceed in parallel; **Task 5 is gated on PR #14's patch existing.**

**Spec:** `docs/superpowers/specs/2026-06-15-show-logs-menu-item-design.md`

---

## File Structure

| File | Responsibility | Task |
|---|---|---|
| `installer/bridge/com.rushautoworks.racestudio3.bridge.plist` | add `StandardErrorPath`/`StandardOutPath` so daemon output persists | 1 |
| `installer/test/unit-bridge-logpath.sh` | assert the plist redirects stderr to `/Library/Logs/aim-bridge.log` | 1 |
| `installer/src/collect-logs.sh` | gather present logs + system-info into a Desktop folder, reveal in Finder | 2 |
| `installer/test/unit-collect-logs.sh` | run collect-logs.sh against a fixture root; assert folder/contents/no-fail-on-absent | 2 |
| `installer/src/show-logs-app.applescript` | thin app wrapper that runs the embedded `collect-logs.sh` | 3 |
| `installer/build/build-apps.sh` | build + brand + embed + stage the new aux app | 4 |
| `installer/wine-patch/winemac-native-menu.patch` | add the **Show Logs…** menu item + `wine_rs3ShowLogs:` (extends PR #14) | 5 |
| `installer/test/unit-winemac-patch.sh` | add Show Logs title + selector assertions (extends PR #14) | 5 |
| `installer/test/run-all.sh` | register the two new unit tests | 2, 4 |

---

## Task 1: Persist the aim-bridge daemon log

**Files:**
- Modify: `installer/bridge/com.rushautoworks.racestudio3.bridge.plist`
- Test: `installer/test/unit-bridge-logpath.sh`
- Modify: `installer/test/run-all.sh`

- [ ] **Step 1: Write the failing test.**

Create `installer/test/unit-bridge-logpath.sh`:

```bash
#!/bin/bash
# unit-bridge-logpath.sh — the aim-bridge LaunchDaemon plist must redirect the daemon's
# stdout+stderr to a persistent, root-writable file so "Show Logs" can collect it. The path is
# /Library/Logs/aim-bridge.log (NOT a /Library/Logs/AiM/ subdir: launchd won't create a missing
# parent dir before the root daemon's first RunAtLoad launch, which would drop the first session).
_T_NAME="unit-bridge-logpath"
HERE="$(cd "$(dirname "$0")" && pwd)"
. "$HERE/harness.sh"

PLIST="$HERE/../bridge/com.rushautoworks.racestudio3.bridge.plist"
LOGPATH="/Library/Logs/aim-bridge.log"

assert_file "$PLIST"
# Valid plist (PlistBuddy parses it).
assert_true "/usr/libexec/PlistBuddy -c 'Print' '$PLIST' >/dev/null 2>&1" "plist parses"
# Both stdio keys present and pointing at the persistent path.
assert_true "[ \"\$(/usr/libexec/PlistBuddy -c 'Print :StandardErrorPath' '$PLIST' 2>/dev/null)\" = '$LOGPATH' ]" "StandardErrorPath -> $LOGPATH"
assert_true "[ \"\$(/usr/libexec/PlistBuddy -c 'Print :StandardOutPath'  '$PLIST' 2>/dev/null)\" = '$LOGPATH' ]" "StandardOutPath -> $LOGPATH"
# Guard against the fragile subdir form.
assert_true "! grep -q '/Library/Logs/AiM/' '$PLIST'" "does not use a missing /Library/Logs/AiM/ subdir"

finish
```

- [ ] **Step 2: Run it, verify it fails.**

Run: `bash installer/test/unit-bridge-logpath.sh`
Expected: FAIL on `StandardErrorPath -> /Library/Logs/aim-bridge.log` (keys absent).

- [ ] **Step 3: Add the keys to the plist.**

In `installer/bridge/com.rushautoworks.racestudio3.bridge.plist`, inside the top-level `<dict>` (e.g. immediately after the `<key>ProcessType</key><string>Background</string>` pair), add:

```xml
    <key>StandardErrorPath</key>
    <string>/Library/Logs/aim-bridge.log</string>
    <key>StandardOutPath</key>
    <string>/Library/Logs/aim-bridge.log</string>
```

- [ ] **Step 4: Run it, verify it passes.**

Run: `bash installer/test/unit-bridge-logpath.sh`
Expected: PASS (all assertions).

- [ ] **Step 5: Register the test in the suite.**

In `installer/test/run-all.sh`, add `unit-bridge-logpath.sh` to the list of unit tests it runs (match the existing pattern for how the other `unit-*.sh` files are invoked).

- [ ] **Step 6: Run the full suite.**

Run: `bash installer/test/run-all.sh`
Expected: ALL TESTS PASSED.

- [ ] **Step 7: Commit.**

```bash
git add installer/bridge/com.rushautoworks.racestudio3.bridge.plist installer/test/unit-bridge-logpath.sh installer/test/run-all.sh
git commit -m "feat: persist aim-bridge daemon log to /Library/Logs/aim-bridge.log"
```

---

## Task 2: collect-logs.sh — gather logs into a Desktop folder

**Files:**
- Create: `installer/src/collect-logs.sh`
- Test: `installer/test/unit-collect-logs.sh`
- Modify: `installer/test/run-all.sh`

Derivation rules (match `installer/src/installer-core.sh`):
- `INSTALL_ROOT = ${RS3_APP_SUPPORT:-$HOME/Library/Application Support/RaceStudio3}`
- Logs live at `$INSTALL_ROOT/logs/{run,install}.log`.
- Bridge log: `/Library/Logs/aim-bridge.log` (Task 1).
- Desktop dir overridable for tests via `RS3_DESKTOP_DIR` (default `$HOME/Desktop`).
- Finder reveal overridable for tests via `RS3_OPEN_CMD` (default `open`).
- Bridge status tool: sibling `…/RaceStudio 3.app/Contents/MacOS/aim-bridge-ctl`, located relative to this script's app bundle; absent in tests — skip gracefully.

- [ ] **Step 1: Write the failing test.**

Create `installer/test/unit-collect-logs.sh`:

```bash
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

# Exactly one AiM-Logs-* folder was created on the fake Desktop.
OUT="$(find "$DESK" -maxdepth 1 -type d -name 'AiM-Logs-*' | head -1)"
assert_true "[ -n '$OUT' ]" "a dated AiM-Logs-* folder was created"
assert_true "[ -f '$OUT/run.log' ]"          "present run.log was copied"
assert_true "grep -q run-log-marker '$OUT/run.log'" "run.log content intact"
assert_true "[ ! -f '$OUT/install.log' ]"    "absent install.log was skipped (not faked)"
assert_true "[ -f '$OUT/system-info.txt' ]"  "system-info.txt written"
assert_true "[ -f '$OUT/README.txt' ]"       "README.txt written"
assert_true "grep -q 'install.log' '$OUT/README.txt'" "README notes the missing install.log"
# Finder reveal was invoked on the output folder.
assert_true "[ \"\$(cat '$OPENLOG' 2>/dev/null)\" = '$OUT' ]" "open was called on the output folder"

finish
```

- [ ] **Step 2: Run it, verify it fails.**

Run: `bash installer/test/unit-collect-logs.sh`
Expected: FAIL on `assert_file` (collect-logs.sh doesn't exist yet).

- [ ] **Step 3: Write collect-logs.sh.**

Create `installer/src/collect-logs.sh`:

```bash
#!/bin/bash
# collect-logs.sh — gather the current RaceStudio 3 logs into a dated folder on the Desktop and
# reveal it in Finder, so a user can hand them to a developer in one drag. Best-effort: every
# source is optional; a missing log is noted in README.txt, never an error. Run by
# "Show RaceStudio 3 Logs.app" (the script is embedded in that app's Resources).
#
# Env overrides (used by the unit test to sandbox everything):
#   RS3_APP_SUPPORT  engine root (default ~/Library/Application Support/RaceStudio3)
#   RS3_DESKTOP_DIR  where the output folder goes (default ~/Desktop)
#   RS3_OPEN_CMD     command used to reveal the folder (default: open)
set -uo pipefail

INSTALL_ROOT="${RS3_APP_SUPPORT:-$HOME/Library/Application Support/RaceStudio3}"
DESKTOP="${RS3_DESKTOP_DIR:-$HOME/Desktop}"
OPEN_CMD="${RS3_OPEN_CMD:-open}"
BRIDGE_LOG="/Library/Logs/aim-bridge.log"

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PINS="$HERE/pins.env"
# aim-bridge-ctl lives in the sibling RaceStudio 3.app (…/AiM/RaceStudio 3.app/Contents/MacOS).
CTL="$HERE/../../../RaceStudio 3.app/Contents/MacOS/aim-bridge-ctl"

ts="$(date '+%Y%m%d-%H%M%S')"
OUT="$DESKTOP/AiM-Logs-$ts"
mkdir -p "$OUT"

missing=()
copy_if_present() {  # $1=source file  $2=basename in OUT
  if [ -f "$1" ]; then cp "$1" "$OUT/$2" 2>/dev/null || missing+=("$2 (copy failed)")
  else missing+=("$2 (not found at $1)"); fi
}
copy_if_present "$INSTALL_ROOT/logs/run.log"     "run.log"
copy_if_present "$INSTALL_ROOT/logs/install.log" "install.log"
copy_if_present "$BRIDGE_LOG"                     "aim-bridge.log"

# system-info.txt — environment a developer needs to read the logs.
{
  echo "AiM RaceStudio 3 — diagnostics"
  echo "collected: $(date)"
  echo
  echo "macOS: $(sw_vers -productVersion 2>/dev/null) ($(sw_vers -buildVersion 2>/dev/null))"
  echo "arch:  $(uname -m)"
  echo "install root: $INSTALL_ROOT"
  if [ -f "$PINS" ]; then
    echo "RS3 version: $(sed -nE 's/^RS3_PINNED_VER="(.*)"/\1/p' "$PINS")"
    echo "pkg rev:     $(sed -nE 's/^RS3_PKG_REV="(.*)"/\1/p' "$PINS")"
  fi
  if [ -x "$CTL" ]; then echo "bridge daemon: $("$CTL" status 2>&1)"
  else echo "bridge daemon: (aim-bridge-ctl not found)"; fi
} > "$OUT/system-info.txt" 2>/dev/null

# README.txt — what's here + what was missing, so an empty-looking folder isn't read as a bug.
{
  echo "These are the current RaceStudio 3 logs, collected $(date)."
  echo "Email or drag this whole folder to whoever is helping you."
  echo
  echo "Included:"
  for f in run.log install.log aim-bridge.log system-info.txt; do
    [ -f "$OUT/$f" ] && echo "  - $f"
  done
  if [ "${#missing[@]}" -gt 0 ]; then
    echo
    echo "Not found (normal if you haven't used that feature yet):"
    printf '  - %s\n' "${missing[@]}"
  fi
} > "$OUT/README.txt" 2>/dev/null

"$OPEN_CMD" "$OUT" 2>/dev/null || true
exit 0
```

- [ ] **Step 4: Make it executable.**

Run: `chmod +x installer/src/collect-logs.sh`

- [ ] **Step 5: Run the test, verify it passes.**

Run: `bash installer/test/unit-collect-logs.sh`
Expected: PASS (all assertions).

- [ ] **Step 6: Register the test in the suite.**

In `installer/test/run-all.sh`, add `unit-collect-logs.sh` alongside the others.

- [ ] **Step 7: Run the full suite.**

Run: `bash installer/test/run-all.sh`
Expected: ALL TESTS PASSED.

- [ ] **Step 8: Commit.**

```bash
git add installer/src/collect-logs.sh installer/test/unit-collect-logs.sh installer/test/run-all.sh
git commit -m "feat: collect-logs.sh gathers RS3 logs into a Desktop folder"
```

---

## Task 3: The "Show RaceStudio 3 Logs" app wrapper

**Files:**
- Create: `installer/src/show-logs-app.applescript`

This mirrors the Import/Uninstall AppleScript apps: it locates its embedded script via
`path to me` and runs it with a timeout, surfacing errors in a dialog. No `is-installed`
gate — collecting logs should work even on a half-broken install (that's the point).

- [ ] **Step 1: Write the app wrapper.**

Create `installer/src/show-logs-app.applescript`:

```applescript
-- Show RaceStudio 3 Logs — a standalone app (installed into /Applications/AiM). Gathers the
-- current RaceStudio 3 logs into a dated folder on your Desktop and opens it in Finder, so you can
-- send them to whoever is helping you. The collector script (collect-logs.sh) is embedded in this
-- app's Resources. No setup required — it works even if RaceStudio 3 won't start.

on run
	set sh to scriptPath()
	try
		with timeout of 120 seconds
			do shell script "bash " & quoted form of sh & " 2>&1"
		end timeout
	on error errMsg
		display dialog "Couldn't collect the logs:" & return & return & errMsg buttons {"OK"} default button 1 with title "Show RaceStudio 3 Logs" with icon stop
	end try
end run

on scriptPath()
	return POSIX path of ((path to me as text) & "Contents:Resources:collect-logs.sh")
end scriptPath
```

- [ ] **Step 2: Syntax-check it compiles.**

Run: `osacompile -o "$TMPDIR/showlogs-test.app" installer/src/show-logs-app.applescript && echo OK && rm -rf "$TMPDIR/showlogs-test.app"`
Expected: `OK` (compiles cleanly; this app has only `on run`, so osacompile makes a plain applet — not a droplet).

- [ ] **Step 3: Commit.**

```bash
git add installer/src/show-logs-app.applescript
git commit -m "feat: Show RaceStudio 3 Logs app wrapper (runs collect-logs.sh)"
```

---

## Task 4: Wire the new app into the build

**Files:**
- Modify: `installer/build/build-apps.sh`

Three insertion points, each mirroring the existing Import/Uninstall lines:
build (~216–220), embed Resources (~225–229), brand (~245–246), stage (~339–340).

- [ ] **Step 1: Add the build + Resources-embed block.**

In `installer/build/build-apps.sh`, immediately after the Uninstall app is built
(`osacompile -o "$UNINSTALL_APP_BUILT" …`), add:

```bash
SHOWLOGS_APP_BUILT="$DIST/Show RaceStudio 3 Logs.app"
osacompile -o "$SHOWLOGS_APP_BUILT" "$SRC/show-logs-app.applescript" || { echo "osacompile show-logs failed"; exit 1; }

# Show Logs runs collect-logs.sh, which reads pins.env for the version. Embed both (no lib/ — the
# collector is standalone and shells to the sibling RaceStudio 3.app for aim-bridge-ctl).
SL_RES="$SHOWLOGS_APP_BUILT/Contents/Resources"
ditto "$SRC/collect-logs.sh" "$SL_RES/collect-logs.sh"
ditto "$SRC/pins.env"        "$SL_RES/pins.env"
chmod +x "$SL_RES/collect-logs.sh"
```

- [ ] **Step 2: Add the brand_applet call.**

After the existing `brand_applet "$UNINSTALL_APP_BUILT" …` line, add (reuse the RS3 icon — no
dedicated Show Logs icns is in scope):

```bash
brand_applet "$SHOWLOGS_APP_BUILT" "$BUNDLE_ID.showlogs" "Show RaceStudio 3 Logs" "$DIST/rs3-logo.icns"
```

> Note: confirm the fallback icon name. Run `ls "$DIST"/*.icns` during the build, or grep
> `build-apps.sh` for the icns the main app uses, and pass that path. The Import/Uninstall apps use
> `rs3-import.icns`/`rs3-uninstall.icns`; Show Logs reuses the primary RS3 icns rather than adding a
> new asset.

- [ ] **Step 3: Add the staging ditto.**

After the existing `ditto "$UNINSTALL_APP_BUILT" "$STAGE/AiM/Uninstall RaceStudio 3.app"` line, add:

```bash
ditto "$SHOWLOGS_APP_BUILT" "$STAGE/AiM/Show RaceStudio 3 Logs.app" || { echo "staging ditto failed (show-logs)"; exit 1; }
```

- [ ] **Step 4: Smoke-build locally (no DMG, no notarize).**

Run: `NO_DMG=1 SKIP_SIGN=1 bash installer/build/build-apps.sh` (use the repo's documented
local-build flags; check the top of `build-apps.sh` for the exact env var names if these differ).
Expected: build completes; `installer/dist/Show RaceStudio 3 Logs.app` exists with
`Contents/Resources/collect-logs.sh` inside.

- [ ] **Step 5: Verify the bundle contents.**

Run:
```bash
ls "installer/dist/Show RaceStudio 3 Logs.app/Contents/Resources/collect-logs.sh" \
   "installer/dist/Show RaceStudio 3 Logs.app/Contents/Resources/pins.env"
/usr/libexec/PlistBuddy -c 'Print :CFBundleName' "installer/dist/Show RaceStudio 3 Logs.app/Contents/Info.plist"
```
Expected: both files listed; `CFBundleName` = `Show RaceStudio 3 Logs`.

- [ ] **Step 6: Functional smoke test (real Desktop).**

Run: `open "installer/dist/Show RaceStudio 3 Logs.app"`
Expected: a `~/Desktop/AiM-Logs-*` folder appears and Finder opens it (it will contain mostly
"not found" notes unless RS3 is installed on this machine — that's correct).

- [ ] **Step 7: Commit.**

```bash
git add installer/build/build-apps.sh
git commit -m "build: ship Show RaceStudio 3 Logs.app in the bundle"
```

---

## Task 5: Add the "Show Logs…" native menu item (GATED on PR #14)

> **Do not start until PR #14's `installer/wine-patch/winemac-native-menu.patch` exists** and adds
> the `wine_rs3OpenAuxApp:` helper + `wine_rs3ImportData:`/`wine_rs3Uninstall:` methods. This task
> regenerates that patch from the Wine source tree (same capture command PR #14 uses).

**Files:**
- Modify: `installer/wine-patch/winemac-native-menu.patch`
- Modify: `installer/test/unit-winemac-patch.sh`

- [ ] **Step 1: Add the failing assertions to the patch test.**

In `installer/test/unit-winemac-patch.sh`, after the existing Import/Uninstall assertions, add:

```bash
grep -qF 'wine_rs3ShowLogs:' "$M"             && ok "Show Logs action present" || bad "Show Logs action missing"
grep -qF 'Show Logs' "$M"                     && ok "Show Logs title present"  || bad "Show Logs title missing"
grep -qF 'Show RaceStudio 3 Logs.app' "$M"    && ok "Show Logs app target present" || bad "Show Logs app target missing"
```

- [ ] **Step 2: Run the test, verify it fails.**

Run: `WINE_SRC=<path> bash installer/test/unit-winemac-patch.sh`
Expected: the three new assertions FAIL (current patch has no Show Logs item); SKIP (77) if
`WINE_SRC` unset.

- [ ] **Step 3: Edit the Wine source.**

In the Wine source tree at `$WINE_SRC/dlls/winemac.drv/cocoa_app.m`, in
`-[WineApplicationController transformProcessToForeground:]`, add a third item immediately after
the Uninstall item PR #14 added (before the separator + Quit):

```objc
    item = [submenu addItemWithTitle:@"Show Logs…"
                              action:@selector(wine_rs3ShowLogs:) keyEquivalent:@""];
    [item setTarget:self];
```

And add the action method next to `wine_rs3Uninstall:`:

```objc
- (void) wine_rs3ShowLogs:(id)sender
{
    [self wine_rs3OpenAuxApp:@"Show RaceStudio 3 Logs.app"];
}
```

- [ ] **Step 4: Regenerate the patch.**

Run (same capture PR #14 Task 1 Step 3 uses):
```bash
cd "$WINE_SRC" && git diff -- dlls/winemac.drv/cocoa_app.m \
  > /path/to/repo/installer/wine-patch/winemac-native-menu.patch
```

- [ ] **Step 5: Run the patch test, verify it passes.**

Run: `WINE_SRC=<path> bash installer/test/unit-winemac-patch.sh`
Expected: PASS (Import/Uninstall/Show Logs + ⌘Q assertions all green).

- [ ] **Step 6: Run the full suite.**

Run: `bash installer/test/run-all.sh`
Expected: ALL TESTS PASSED (unit-winemac-patch SKIPs without `WINE_SRC`).

- [ ] **Step 7: Commit.**

```bash
git add installer/wine-patch/winemac-native-menu.patch installer/test/unit-winemac-patch.sh
git commit -m "feat: add Show Logs… native app-menu item (extends winemac patch)"
```

---

## Task 6: Build-output + on-device verification (GATED on Task 5 + PR #14 build wiring)

> Requires PR #14 Task 3 (the `build-apps.sh` swap of the from-source `winemac.so`) to be in place,
> so the rebuilt driver actually carries the menu patch.

- [ ] **Step 1: Full build via the swap path.**

Run: `NO_DMG=1 bash installer/build/build-apps.sh`
Expected: build completes; `Show RaceStudio 3 Logs.app` staged in the bundle and the patched
`winemac.so` swapped in.

- [ ] **Step 2: Assert the menu item compiled into the driver.**

Run:
```bash
SO="installer/dist/RaceStudio 3.app/Contents/Resources/wine/lib/wine/x86_64-unix/winemac.so"
strings -a "$SO" | grep -E 'wine_rs3ShowLogs:|Show Logs'
```
Expected: both strings present.

- [ ] **Step 3: On-device acceptance.**

- [ ] Install/launch the built app; bring an RS3 window to the front.
- [ ] Open the bold **RaceStudio 3** app menu → **Import…**, **Uninstall…**, **Show Logs…** all appear above Quit.
- [ ] Click **Show Logs…** → a `~/Desktop/AiM-Logs-*` folder opens in Finder containing `run.log` (and `aim-bridge.log` if WiFi was used) + `system-info.txt`.
- [ ] Confirm `system-info.txt` shows the correct macOS build, RS3 version, and bridge daemon status.

- [ ] **Step 4: Record the macOS build number + result in the PR.** No commit (verification only).

---

## Self-Review notes

- **Spec coverage:** Show Logs app + collect-logs.sh (Tasks 2,3,4); Desktop folder output + system-info + README (Task 2); daemon log persistence (Task 1); menu wiring (Task 5); build wiring (Task 4); on-device (Task 6). Deliverable 1 (PR #14) is the stated prerequisite, not re-planned here. ✓
- **Path consistency:** `/Library/Logs/aim-bridge.log` is identical in the plist (Task 1), `collect-logs.sh` `BRIDGE_LOG` (Task 2), and the spec. ✓
- **Selector/title consistency:** `wine_rs3ShowLogs:` / `Show Logs…` / `Show RaceStudio 3 Logs.app` are identical in the patch (Task 5 Step 3), the unit test (Task 5 Step 1), and the build-output assertion (Task 6 Step 2), and the app bundle name matches the `ditto` target in Task 4 Step 3 and `brand_applet` in Task 4 Step 2. ✓
- **Test sandboxing:** `unit-collect-logs.sh` overrides `RS3_APP_SUPPORT`/`RS3_DESKTOP_DIR`/`RS3_OPEN_CMD` so it never touches the real Desktop or Finder. ✓
- **Open item flagged inline:** Task 4 Step 2 notes the fallback icns name must be confirmed against `build-apps.sh` rather than assumed.
```
