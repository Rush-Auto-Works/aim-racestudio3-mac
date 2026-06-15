# Execution prompt: finish PR #14 (native winemac menu) → then Show Logs Tasks 5–6

> Hand this whole file to an implementing session (or `subagent-driven-development` lead). It is self-contained: it names the two plans, the exact ordering, the dependency facts, and the verification gates. Do NOT start until the prerequisites in "State going in" are true.

## Goal

Land the native macOS app-menu items in RaceStudio 3's Wine-owned menu bar, then add **Show Logs…** as a third item. End state: focusing an RS3 window and opening the bold **RaceStudio 3** app menu shows **Import RaceStudio 3 Data…**, **Uninstall RaceStudio 3…**, **Show Logs…** above a ⌘Q **Quit**, each launching the matching standalone app in `/Applications/AiM`.

## Two plans this executes (read both, verbatim — they contain the exact code/tests)

1. **PR #14 — native menu mechanism:** `docs/plans/2026-06-07-native-menu-items.md` (Tasks 0–6). Builds a from-source `winemac.so`, patches `dlls/winemac.drv/cocoa_app.m` to add Import + Uninstall, wires the module swap into `installer/build/build-apps.sh`, folds ⌘Q into the source patch (retiring `patch-wine-cmdq.py`), verifies on-device. Branch: `feat/native-menu-items` (PR #14, currently plan-only).
2. **Show Logs — Tasks 5–6:** `docs/superpowers/plans/2026-06-15-show-logs-menu-item.md` (Tasks 5 and 6 only — Tasks 1–4 already shipped in PR #17). Task 5 extends the winemac patch with the **Show Logs…** item + `wine_rs3ShowLogs:`. Task 6 is full-build + on-device verification.

## State going in (verify before starting)

- **PR #17 must be merged to `main`** (the Show Logs app + `collect-logs.sh` + daemon-log persistence). Confirm `installer/src/show-logs-app.applescript`, `installer/src/collect-logs.sh`, and `Show RaceStudio 3 Logs.app` staging in `build-apps.sh` are present on `main`. Task 5 wires the menu item to an app that only exists once #17 is in.
- Work on the `feat/native-menu-items` branch, rebased on the post-#17 `main` (so it has both the winemac patch infra *and* the Show Logs app). Tasks 5–6 are commits on that same branch — do NOT open a separate branch; the menu item and the winemac build must ship together.

## Hard dependency: ordering is non-negotiable

PR #14's `installer/wine-patch/winemac-native-menu.patch` and its `wine_rs3OpenAuxApp:` helper **do not exist yet** — they are created by #14 Tasks 0–4. Task 5 below *edits that patch*. So:

```
#14 Task 0  (prove winemac.so single-module build)            ─┐
#14 Task 1  (cocoa_app.m patch: Import + Uninstall items)      │  must complete first,
#14 Task 2  (confirm launch action against real apps)          │  in this order
#14 Task 3  (wire patch + module swap into build-apps.sh)      │
#14 Task 4  (fold ⌘Q into source patch; retire binary patcher)─┘
SHOW-LOGS Task 5 (add Show Logs… item — extends the patch)    ← only after #14 Task 1 exists
SHOW-LOGS Task 6 / #14 Tasks 5–6 (build-output + on-device)   ← run together, one device pass
```

## Key technical facts (so you don't re-derive them)

- **The build is macOS-only and network-heavy.** `installer/bridge/wine-patch/build-wine-dlls.sh` already does `./configure --enable-archs=i386,x86_64 && make __tooldeps__` against pinned Wine source (`WINE_PINNED_VER`, currently 11.9) and builds individual modules. #14 Task 0 extends this to `make dlls/winemac.drv` → the unix-side `winemac.so`. This CANNOT run in a sandbox (fetches Gcenx Wine + Wine source). Run on `macos-14` CI or a real Mac.
- **The single-module swap is ABI-safe** because the from-source module matches the bundled Gcenx Wine version. #14 Task 0 Step 3 proves an *unpatched* rebuilt `winemac.so` is a drop-in BEFORE any patch. If parity fails (Gcenx staging patches affect winemac), STOP and surface — don't fake it.
- **The patch is one file**, `installer/wine-patch/winemac-native-menu.patch` (diff of `dlls/winemac.drv/cocoa_app.m`). All three items are added in `-[WineApplicationController transformProcessToForeground:]` just before the Quit item, each via the shared `wine_rs3OpenAuxApp:` helper that `/usr/bin/open`s an app from `/Applications/AiM` (with the `~/Applications/AiM` fallback). The exact ObjC is in #14's plan under "The exact source change."
- **CI build-vs-commit-blob is an open decision** (#14 Task 3 Step 1): build `winemac.so` in CI and swap, or commit a prebuilt patched blob. Pick the SAME strategy already chosen for the bridge's `ws2_32.dll`/`wlanapi.dll` and document it in `installer/wine-patch/README.md`.

## SHOW-LOGS Task 5 — add the Show Logs… menu item (verbatim from the Show Logs plan)

> Gated on #14 Task 1 (the patch + `wine_rs3OpenAuxApp:` exist). Regenerate the patch from the Wine source tree (same capture command #14 uses).

Files: modify `installer/wine-patch/winemac-native-menu.patch`; modify `installer/test/unit-winemac-patch.sh`.

1. **Add failing assertions** to `installer/test/unit-winemac-patch.sh`, after the Import/Uninstall assertions:
   ```bash
   grep -qF 'wine_rs3ShowLogs:' "$M"             && ok "Show Logs action present" || bad "Show Logs action missing"
   grep -qF 'Show Logs' "$M"                     && ok "Show Logs title present"  || bad "Show Logs title missing"
   grep -qF 'Show RaceStudio 3 Logs.app' "$M"    && ok "Show Logs app target present" || bad "Show Logs app target missing"
   ```
2. **Run:** `WINE_SRC=<path> bash installer/test/unit-winemac-patch.sh` → the three new assertions FAIL (SKIP 77 if `WINE_SRC` unset).
3. **Edit the Wine source** `$WINE_SRC/dlls/winemac.drv/cocoa_app.m`, in `transformProcessToForeground:`, add a third item right after the Uninstall item (before the separator + Quit):
   ```objc
       item = [submenu addItemWithTitle:@"Show Logs…"
                                 action:@selector(wine_rs3ShowLogs:) keyEquivalent:@""];
       [item setTarget:self];
   ```
   and the action method next to `wine_rs3Uninstall:`:
   ```objc
   - (void) wine_rs3ShowLogs:(id)sender
   {
       [self wine_rs3OpenAuxApp:@"Show RaceStudio 3 Logs.app"];
   }
   ```
4. **Regenerate the patch:** `cd "$WINE_SRC" && git diff -- dlls/winemac.drv/cocoa_app.m > <repo>/installer/wine-patch/winemac-native-menu.patch`
5. **Run:** `WINE_SRC=<path> bash installer/test/unit-winemac-patch.sh` → PASS (Import/Uninstall/Show Logs + ⌘Q all green).
6. **Run:** `bash installer/test/run-all.sh` → ALL TESTS PASSED (the winemac patch test SKIPs without `WINE_SRC`).
7. **Commit:** `git commit -m "feat: add Show Logs… native app-menu item (extends winemac patch)"`

## SHOW-LOGS Task 6 / #14 Tasks 5–6 — build-output + on-device (run as one device pass)

> Requires #14 Task 3 (build-apps.sh swaps the from-source `winemac.so`).

1. Full build via the swap path: `NO_DMG=1 bash installer/build/build-apps.sh`.
2. Assert all three actions + titles compiled into the driver:
   ```bash
   SO="installer/dist/RaceStudio 3.app/Contents/Resources/wine/lib/wine/x86_64-unix/winemac.so"
   strings -a "$SO" | grep -E 'wine_rs3ImportData:|wine_rs3Uninstall:|wine_rs3ShowLogs:|Import RaceStudio 3 Data|Uninstall RaceStudio 3|Show Logs'
   otool -tV "$SO" | grep -nE 'movl\s+\$0x100000, %edx'   # Quit mask now ⌘Q (0x100000)
   ```
3. `codesign --verify --strict "installer/dist/RaceStudio 3.app"` → valid.
4. **On-device:** install/launch the built app, focus an RS3 window, open the **RaceStudio 3** app menu:
   - Import…, Uninstall…, **Show Logs…** appear above Quit; Quit shows ⌘Q.
   - Click each → the matching `/Applications/AiM` app launches. Show Logs → `~/Desktop/AiM-Logs-*` opens in Finder with `run.log` + `system-info.txt` (+ `aim-bridge.log` if WiFi was exercised).
   - ⌘Q still quits RS3; phase-1 ⌘C/⌘V still work in a text field (no regression).
5. Record the macOS build number + result in the PR. Update `CLAUDE.md`'s "Don't retry" entry — the "Custom items in Wine's macOS app menu … Not worth it" line is now **SUPERSEDED** (achieved via a single-module source build).

## Definition of done

- `feat/native-menu-items` carries #14 Tasks 0–4 + Show Logs Tasks 5–6, all commits TDD-gated.
- `unit-winemac-patch.sh` asserts all three items (with `WINE_SRC` set); `run-all.sh` green.
- On-device: all three menu items render and fire; ⌘Q intact; no ⌘C/⌘V regression.
- PR #14 updated: Status block refreshed, CLAUDE.md "Not worth it" entry superseded, build-vs-blob CI decision documented.
- Merge gates: CI green **and** CodeRabbit `reviewDecision == APPROVED` before merge (per project CLAUDE.md).
