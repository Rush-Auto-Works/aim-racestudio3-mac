# Show Logs app + native menu item — design

**Date:** 2026-06-15
**Status:** Approved, ready for implementation plan
**Builds on:** PR #14 (`feat/native-menu-items`) and its plan `docs/plans/2026-06-07-native-menu-items.md`

## Problem

A user can't get WiFi to the AiM dash working under Wine, and there is no easy way for
them to hand their logs to a developer. Two of the three runtime log sources land in the
engine's data root where a non-technical user won't find them, and the `aim-bridge`
daemon — the single most useful signal for a WiFi failure — writes to stderr with no
persistent destination, so its output is lost entirely.

The fix is a one-click "Show Logs" app that gathers the current logs into a folder on the
Desktop and reveals it in Finder, plus the small daemon change that makes the bridge log
persist so there is something to gather.

The same work also finishes the long-stalled native macOS app-menu integration (PR #14):
once RS3 has a real app menu, "Show Logs" is a natural third item next to Import and
Uninstall.

## Scope: two deliverables, in order

### Deliverable 1 — Finish PR #14 unchanged

Execute the existing 7-task plan (`docs/plans/2026-06-07-native-menu-items.md`, Tasks 0–6)
as written, no changes:

- Build a from-source `winemac.so` via the single-module recipe the bridge team proved
  (`installer/bridge/wine-patch/README.md`).
- Patch `dlls/winemac.drv/cocoa_app.m` to add **Import RaceStudio 3 Data…** and
  **Uninstall RaceStudio 3…** above Quit, each launching the existing aux app in
  `/Applications/AiM` via the `wine_rs3OpenAuxApp:` helper.
- Wire the module swap into `installer/build/build-apps.sh`.
- Fold the ⌘Q remap into the source patch and retire `patch-wine-cmdq.py`.
- Verify on-device.

This deliverable lands first so Deliverable 2's menu item has a menu to attach to.

### Deliverable 2 — "Show Logs" app + menu item

A new aux app `Show RaceStudio 3 Logs.app` in `/Applications/AiM`, peer to Import and
Uninstall (same AppleScript + `lib` mold), and a third winemac menu item **Show Logs…**
that launches it through the same `wine_rs3OpenAuxApp:` helper PR #14 adds.

## What "Show Logs" does

A script `installer/src/collect-logs.sh`, run by the app wrapper, does the minimum:

1. Create a timestamped folder `~/Desktop/AiM-Logs-YYYYMMDD-HHMMSS/`.
2. Copy in whatever exists — each optional, never fail if absent:
   - `$INSTALL_ROOT/logs/run.log` — RS3 runtime stdout/stderr
   - `$INSTALL_ROOT/logs/install.log` — install/import engine log
   - `/Library/Logs/aim-bridge.log` — the bridge daemon log (see below)
   - a generated `system-info.txt`: macOS build (`sw_vers`), app `CFBundleVersion`,
     `INSTALL_ROOT` path, bridge registration state (`aim-bridge-ctl status`), and the
     pins (`RS3_PINNED_VER` / `RS3_PKG_REV`)
3. Write a `README.txt` listing what was and wasn't found, so an otherwise-empty folder
   isn't mistaken for a bug.
4. `open` the folder in Finder.

Output destination is a **self-contained folder on the Desktop** (not a reveal-in-place of
the engine's `logs/` dir): easy for the user to drag into an email, and it can carry the
bridge log and system-info that don't live under `INSTALL_ROOT`.

### Deliberately out of scope (YAGNI)

No zipping, no redaction, no reachability probes, no WiFi-specific diagnostic checks. This
is "here are the current logs, revealed in Finder," nothing more. A WiFi-specific
diagnostic suite can be layered on later if the plain log dump proves insufficient.

## Daemon log persistence (load-bearing)

`aim-bridge.swift` already writes to stderr (line 54), but
`com.rushautoworks.racestudio3.bridge.plist` sets no `StandardErrorPath`, so the output is
discarded. Add to the plist:

```xml
<key>StandardErrorPath</key><string>/Library/Logs/aim-bridge.log</string>
<key>StandardOutPath</key><string>/Library/Logs/aim-bridge.log</string>
```

The daemon runs as root, so a system-wide, root-writable path is correct (not
`~/Library/Logs`, which the root daemon can't reliably resolve to the logged-in user).
`/Library/Logs/` is chosen because it always exists and is root-writable: `launchd` does
not reliably create parent directories for `StandardErrorPath`, and the daemon's first
`RunAtLoad` launch happens before any code could `mkdir` a subdir, so a
`/Library/Logs/AiM/` subfolder would silently drop the first session's output.
`collect-logs.sh` reads the log from this path. Without this change "Show
Logs" has no bridge signal — the most useful thing for the WiFi case that motivated the
feature.

## Menu wiring

Extend PR #14's `installer/wine-patch/winemac-native-menu.patch`:

- One more `addItemWithTitle:@"Show Logs…"` immediately before Quit.
- A `wine_rs3ShowLogs:` method that calls
  `wine_rs3OpenAuxApp:@"Show RaceStudio 3 Logs.app"`.

Final app-menu order: `… Show All`, separator, **Import RaceStudio 3 Data…**,
**Uninstall RaceStudio 3…**, **Show Logs…**, separator, **Quit (⌘Q)**.

## Build wiring

`installer/build/build-apps.sh` builds the new aux app alongside Import and Uninstall on
the same bundling code path. The bundle-name ↔ patch-string consistency check (PR #14
Task 2) gains the third app name.

## Testing

Following the repo's TDD pattern (`installer/test/run-all.sh`):

- `installer/test/unit-collect-logs.sh` — run `collect-logs.sh` against a fixture
  `INSTALL_ROOT` with synthetic logs. Assert: the Desktop folder is created, present logs
  are copied, absent logs are skipped without error, `system-info.txt` and `README.txt`
  exist. Override the Desktop path and the `open` invocation via env so the test is
  CI-safe (no real Finder, writes under a temp dir).
- Extend `installer/test/unit-winemac-patch.sh` (PR #14 Task 1) with `Show Logs` title and
  `wine_rs3ShowLogs:` selector assertions.
- `bash installer/test/run-all.sh` green before each commit.

## Components and boundaries

| Unit | Purpose | Depends on |
|---|---|---|
| `collect-logs.sh` | gather present logs + system-info into a Desktop folder, reveal in Finder | `INSTALL_ROOT` layout, `aim-bridge-ctl`, `pins.env` |
| `Show RaceStudio 3 Logs.app` | thin AppleScript wrapper that runs `collect-logs.sh` | aux-app mold (`lib/ui.sh`) |
| bridge plist `StandardErrorPath` | persist daemon stderr to `/Library/Logs/aim-bridge.log` | daemon runs as root |
| winemac patch `wine_rs3ShowLogs:` | menu item → launch the aux app | PR #14's `wine_rs3OpenAuxApp:` |
| `build-apps.sh` aux-app build | ship the new app in the bundle | existing Import/Uninstall build path |

Each unit is independently testable: `collect-logs.sh` via the unit test, the patch via the
string-assertion test, the daemon log path by inspecting the plist.
