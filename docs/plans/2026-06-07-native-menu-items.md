# Native macOS Menu Items (Import / Uninstall) Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add **Import RaceStudio 3 Data…** and **Uninstall RaceStudio 3…** items to RS3's native macOS app menu (the bold top-left "RaceStudio 3" menu), each launching the existing standalone app in `/Applications/AiM`.

**Architecture:** A source patch to `dlls/winemac.drv/cocoa_app.m`, compiled with the **lightweight single-module Wine build** the bridge team already proved out (`installer/bridge/wine-patch/README.md`): install the toolchain, configure the pinned Wine source, `make __tooldeps__`, then build *only the one module* and swap it into the prebuilt Gcenx bundle. For the bridge that module is the PE `ws2_32.dll`; for menu items it's the unix-side `winemac.so`. The patch also folds in the ⌘Q remap currently done as a post-build binary patch (`patch-wine-cmdq.py`), so there is ONE source-level menu patch and the binary patcher retires.

**Tech Stack:** Wine 11.9 source (matches `WINE_PINNED_VER`), Objective-C / Cocoa (`winemac.drv`), `mingw-w64`/`bison`/`flex` toolchain, `git apply` for the patch, bash build glue (`installer/build/build-apps.sh`), codesign/notarize.

---

## What changed the feasibility (read first)

Earlier framing assumed "rebuild all of Wine" — a multi-hour pipeline. The bridge team's `installer/bridge/wine-patch/README.md` shows it's much lighter: **build a single module from the pinned Wine source and swap it into the prebuilt bundle**, which is ABI-compatible because it's the same Wine version. The menu items reuse that exact technique on a different module:

| | Bridge (existing) | Menu items (this plan) |
|---|---|---|
| Source file patched | `dlls/ws2_32/socket.c` | `dlls/winemac.drv/cocoa_app.m` |
| Built artifact | `ws2_32.dll` (PE, both archs) | `winemac.so` (x86_64-unix) |
| Swap target in bundle | `lib/wine/{x86_64,i386}-windows/ws2_32.dll` | `lib/wine/x86_64-unix/winemac.so` |
| Build command | `make dlls/ws2_32/ws2_32.dll` | `make dlls/winemac.drv` |

**Shared with the bridge:** the toolchain (`brew install mingw-w64 bison flex`), the `configure --enable-archs=i386,x86_64` + `make __tooldeps__` prelude, and the **CI integration OPEN DECISION** (build-in-CI vs commit-a-prebuilt-blob — see README §"CI integration"). Do these once for both modules. **Coordinate the patch directory:** the bridge put its patch + recipe under `installer/bridge/wine-patch/`. Since that dir now hosts a non-bridge patch too, either co-locate there or generalize it to `installer/wine-patch/`; this plan writes paths as `installer/wine-patch/` and flags the rename as a coordination item with the bridge work.

**Current ⌘Q state:** PR #13 ships `patch-wine-cmdq.py` (a post-download binary flip) NOW, before any module build. Task 4 retires it and moves the same change into `cocoa_app.m`. Do Task 4 **only** in the same change that makes `build-apps.sh` swap in the from-source `winemac.so` — never remove the binary patch while the bundle's winemac is still the stock prebuilt.

## The exact source change (reference for all tasks)

In `dlls/winemac.drv/cocoa_app.m`, the app menu is built in `-[WineApplicationController transformProcessToForeground:]`. The Quit item is created there with:

```objc
item = [submenu addItemWithTitle:title action:@selector(terminate:) keyEquivalent:@"q"];
[item setKeyEquivalentModifierMask:NSEventModifierFlagCommand | NSEventModifierFlagOption];
```

**(a) Insert two items + a separator immediately BEFORE the Quit item** (menu order becomes `… Show All`, separator, **Import**, **Uninstall**, separator, **Quit**):

```objc
[submenu addItem:[NSMenuItem separatorItem]];
item = [submenu addItemWithTitle:@"Import RaceStudio 3 Data…"
                          action:@selector(wine_rs3ImportData:) keyEquivalent:@""];
[item setTarget:self];
item = [submenu addItemWithTitle:@"Uninstall RaceStudio 3…"
                          action:@selector(wine_rs3Uninstall:) keyEquivalent:@""];
[item setTarget:self];
```

**(b) Fold the ⌘Q remap into source** (replaces `patch-wine-cmdq.py`): change the Quit modifier-mask line to

```objc
[item setKeyEquivalentModifierMask:NSEventModifierFlagCommand];
```

**Add three methods to the `WineApplicationController` implementation** (near the other menu-action methods, e.g. by `-hideOtherApplications:`):

```objc
- (void) wine_rs3OpenAuxApp:(NSString*)appName
{
    /* The Import/Uninstall apps live in the AiM folder; /Applications first, then the
       per-user fallback the engine uses when /Applications isn't writable. Launch via
       /usr/bin/open (universal, no deprecated NSWorkspace API, runs the .app natively even
       though winemac runs x86_64-under-Rosetta). */
    NSArray<NSString*>* roots = @[@"/Applications/AiM",
                                  [NSHomeDirectory() stringByAppendingPathComponent:@"Applications/AiM"]];
    for (NSString* root in roots)
    {
        NSString* path = [root stringByAppendingPathComponent:appName];
        if ([[NSFileManager defaultManager] fileExistsAtPath:path])
        {
            @try { [NSTask launchedTaskWithLaunchPath:@"/usr/bin/open" arguments:@[path]]; }
            @catch (NSException *e) { NSBeep(); }
            return;
        }
    }
    NSBeep();   /* neither location present — should not happen for an installed app */
}

- (void) wine_rs3ImportData:(id)sender
{
    [self wine_rs3OpenAuxApp:@"Import RaceStudio 3 Data.app"];
}

- (void) wine_rs3Uninstall:(id)sender
{
    [self wine_rs3OpenAuxApp:@"Uninstall RaceStudio 3.app"];
}
```

Notes baked in from prior findings:
- `self` (the `WineApplicationController`) owns these methods; `setTarget:self` guarantees the action reaches it rather than walking the responder chain.
- App titles match the bundles built in `build-apps.sh` (`Import RaceStudio 3 Data.app`, `Uninstall RaceStudio 3.app`) — keep in sync if those bundle names change.
- Menu actions run on the main thread — safe for AppKit/NSTask.

---

## Task 0: Build a patched `winemac.so` from source (lightweight, reuses the bridge recipe)

**Files:**
- Create: `installer/wine-patch/winemac-native-menu.patch` (the cocoa_app.m diff — authored in Task 1; here we just prove the build)
- Create/extend: `installer/wine-patch/README.md` (document the winemac build, mirroring the ws2_32 one)

> Shares the toolchain + source checkout with `installer/bridge/wine-patch/`. If the bridge work already has the Wine 11.9 source tree + toolchain set up, reuse it and only add `make dlls/winemac.drv`.

- [ ] **Step 1: Toolchain + source** (same as the ws2_32 README):

```bash
brew install mingw-w64 bison flex
curl -LO https://dl.winehq.org/wine/source/11.x/wine-11.9.tar.xz   # match WINE_PINNED_VER
tar xf wine-11.9.tar.xz && cd wine-11.9
```

- [ ] **Step 2: Build just winemac.drv** (unpatched first, to prove the toolchain):

```bash
./configure --enable-archs=i386,x86_64
make __tooldeps__
make dlls/winemac.drv          # produces the unix-side winemac.so
find . -name 'winemac.so' -path '*x86_64-unix*'   # locate the build output
```
Expected: a freshly built `winemac.so`. (ABI note from the ws2_32 README: a vanilla-11.9 module swapped into the Gcenx **staging** 11.9 bundle should be compatible — verify on first build.)

- [ ] **Step 3: Verify functional parity (unpatched).** Swap the built `winemac.so` into a copy of the bundled Wine tree (`lib/wine/x86_64-unix/winemac.so`) and launch RS3 through it (`build-apps.sh` with `SKIP_SIGN=1` for speed, or a manual bundle swap). Expected: RS3 launches and the app menu renders exactly as today. Proves the from-source driver is a drop-in BEFORE any patch.

- [ ] **Step 4: Commit the build doc.**

```bash
git add installer/wine-patch/README.md
git commit -m "docs: lightweight winemac.drv build for native menu items (reuses ws2_32 recipe)"
```

**Blocking note:** if Step 2/3 can't reach parity (build fails or RS3 misbehaves with the rebuilt module), STOP and surface to the user — the bundled Gcenx build may carry staging patches that affect winemac. Don't fake a build.

---

## Task 1: Author the `cocoa_app.m` patch (menu items only)

**Files:**
- Create: `installer/wine-patch/winemac-native-menu.patch`
- Test: `installer/test/unit-winemac-patch.sh`

- [ ] **Step 1: Write the failing test** — assert the patch applies cleanly to the pinned source and adds the expected selectors/titles.

```bash
# installer/test/unit-winemac-patch.sh
#!/bin/bash
# unit-winemac-patch.sh — the winemac menu patch applies cleanly to the pinned Wine source and
# introduces the new menu-item selectors + the ⌘Q-only mask. Requires the Wine source tree at
# $WINE_SRC (from Task 0); skips (77) if absent so the suite still runs without it.
_T_NAME="unit-winemac-patch"
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PATCH="$HERE/../wine-patch/winemac-native-menu.patch"
SRC="${WINE_SRC:-}"
[ -n "$SRC" ] && [ -f "$SRC/dlls/winemac.drv/cocoa_app.m" ] || { echo "  (WINE_SRC unset — skipping)"; exit 77; }

P=0; F=0
ok(){ P=$((P+1)); echo "  ok   $1"; }; bad(){ F=$((F+1)); echo "  FAIL $1" >&2; }
WORK="$(mktemp -d "${TMPDIR:-/tmp}/winemacpatch.XXXXXX")"; trap 'rm -rf "$WORK"' EXIT
cp -R "$SRC" "$WORK/src"

git -C "$WORK/src" apply --check "$PATCH" 2>/dev/null && ok "patch applies cleanly" || bad "patch does not apply"
git -C "$WORK/src" apply "$PATCH" 2>/dev/null || true
M="$WORK/src/dlls/winemac.drv/cocoa_app.m"
grep -qF 'wine_rs3ImportData:' "$M"      && ok "Import action present"    || bad "Import action missing"
grep -qF 'wine_rs3Uninstall:' "$M"       && ok "Uninstall action present" || bad "Uninstall action missing"
grep -qF 'Import RaceStudio 3 Data' "$M" && ok "Import title present"     || bad "Import title missing"
grep -qF 'Uninstall RaceStudio 3' "$M"   && ok "Uninstall title present"  || bad "Uninstall title missing"
# ⌘Q fold-in (added in Task 4): Quit mask Command-only.
grep -qE 'setKeyEquivalentModifierMask:NSEventModifierFlagCommand\]' "$M" && ok "Quit is ⌘Q (Command only)" || bad "Quit mask not folded to ⌘Q"
echo "unit-winemac-patch: $P passed, $F failed"; [ "$F" -eq 0 ]
```

- [ ] **Step 2: Run it.** Run: `WINE_SRC=<path> bash installer/test/unit-winemac-patch.sh`. Expected: FAIL "patch does not apply" (file absent), or SKIP (77) if `WINE_SRC` unset.

- [ ] **Step 3: Create the patch.** In the Wine source tree, edit `dlls/winemac.drv/cocoa_app.m` per change (a) + the three methods (NOT the ⌘Q fold — that's Task 4), then capture:

```bash
cd "$WINE_SRC" && git diff -- dlls/winemac.drv/cocoa_app.m \
  > /path/to/repo/installer/wine-patch/winemac-native-menu.patch
```

- [ ] **Step 4: Run the test.** All assertions PASS except the ⌘Q one (added in Task 4). Gate Task 1's commit on the four item/title/selector assertions only.

- [ ] **Step 5: Commit.**

```bash
git add installer/wine-patch/winemac-native-menu.patch installer/test/unit-winemac-patch.sh
git commit -m "feat: winemac source patch adds Import/Uninstall app-menu items"
```

---

## Task 2: Confirm the launch action against the real apps (manual harness)

**Files:** reference `installer/build/build-apps.sh` (bundle names), the built `/Applications/AiM/*.app`.

- [ ] **Step 1: Verify the bundle names match.** Run: `grep -nE 'Import RaceStudio 3 Data|Uninstall RaceStudio 3' installer/build/build-apps.sh`. Expected: both `.app` names present, exactly matching the strings in `wine_rs3OpenAuxApp:` calls. Fix the patch strings if they differ.

- [ ] **Step 2: Smoke-test `open` resolves the paths** (no Wine needed):

Run: `open "/Applications/AiM/Import RaceStudio 3 Data.app"` and `open "/Applications/AiM/Uninstall RaceStudio 3.app"` (or the `~/Applications/AiM` fallback if installed there).
Expected: each app launches — proves the action's launch mechanism before it's wired through Wine.

- [ ] **Step 3: No commit** (verification only).

---

## Task 3: Wire the patch + module swap into the build

**Files:**
- Modify: `installer/build/build-apps.sh` (apply patch + build + swap `winemac.so`, or swap a committed prebuilt — per the CI OPEN DECISION)
- Modify: `installer/wine-patch/README.md`

- [ ] **Step 1: Resolve the CI OPEN DECISION with the bridge work.** Pick the SAME strategy for both modules: (1) build `ws2_32.dll` + `winemac.so` from source in CI and swap both, or (2) commit prebuilt patched blobs and swap. Document the choice in `installer/wine-patch/README.md`.

- [ ] **Step 2: Implement the swap.** In `build-apps.sh`, after Wine is bundled (current step 1b) and BEFORE signing, replace the bundled `lib/wine/x86_64-unix/winemac.so` with the patched build output (built in CI, or copied from a committed blob). Fail-loud if the target file is missing (mirror the appname/cmd-q `patched>0` guards).

- [ ] **Step 3: Commit.**

```bash
git add installer/build/build-apps.sh installer/wine-patch/README.md
git commit -m "build: swap patched winemac.so (native menu items) into the bundle"
```

---

## Task 4: Fold the ⌘Q remap into the source patch; retire the binary patcher

> Do this ONLY in the same change that makes `build-apps.sh` ship the from-source `winemac.so` (Task 3). While the bundle's winemac is still the stock prebuilt, `patch-wine-cmdq.py` is the live mechanism and must stay.

**Files:**
- Modify: `installer/wine-patch/winemac-native-menu.patch` (add the mask change)
- Delete: `installer/build/patch-wine-cmdq.py`, `installer/test/unit-patch-cmdq.sh`
- Modify: `installer/build/build-apps.sh` (remove step 1d), `installer/test/run-all.sh` (drop `unit-patch-cmdq.sh`), `codemaps/build-release.md`

- [ ] **Step 1:** Add change (b) (`setKeyEquivalentModifierMask:NSEventModifierFlagCommand`) to the Wine source, regenerate `winemac-native-menu.patch` (same capture command as Task 1 Step 3). The ⌘Q assertion in `unit-winemac-patch.sh` now passes.

- [ ] **Step 2: Run** `WINE_SRC=<path> bash installer/test/unit-winemac-patch.sh`. Expected: PASS (all assertions incl. ⌘Q).

- [ ] **Step 3:** Remove the binary patcher + wiring:

```bash
git rm installer/build/patch-wine-cmdq.py installer/test/unit-patch-cmdq.sh
```
Delete the "1d. native Cmd-Q" block from `installer/build/build-apps.sh`, drop `unit-patch-cmdq.sh` from `installer/test/run-all.sh`, and update the `1d` row + `patch-wine-cmdq.py` row in `codemaps/build-release.md` to point at the source patch.

- [ ] **Step 4: Run** `bash installer/test/run-all.sh`. Expected: ALL TESTS PASSED (no `unit-patch-cmdq.sh`; `unit-winemac-patch.sh` SKIPs without `WINE_SRC`).

- [ ] **Step 5: Commit.**

```bash
git add -A
git commit -m "refactor: move ⌘Q remap into the winemac source patch; retire binary patcher"
```

---

## Task 5: Build and verify the items ship (BLOCKED on Task 0 build + Task 3 wiring)

**Files:** reference `installer/build/build-apps.sh`, the built `RaceStudio 3.app`.

- [ ] **Step 1:** Build via the swap path (`bash installer/build/build-apps.sh`, `NO_DMG=1` locally).

- [ ] **Step 2: Assert the new items compiled in.** Run:

```bash
SO="installer/dist/RaceStudio 3.app/Contents/Resources/wine/lib/wine/x86_64-unix/winemac.so"
strings -a "$SO" | grep -E 'wine_rs3ImportData:|wine_rs3Uninstall:|Import RaceStudio 3 Data|Uninstall RaceStudio 3'
otool -tV "$SO" | grep -nE 'movl\s+\$0x1[08]0000, %edx'   # Quit site now 0x100000 (⌘Q)
```
Expected: all four strings present; the Quit mask is `0x100000`.

- [ ] **Step 3:** `codesign --verify --strict "installer/dist/RaceStudio 3.app"`. Expected: valid.

- [ ] **Step 4: No commit** (build-output verification).

---

## Task 6: On-device acceptance (BLOCKED on Task 5)

- [ ] **Step 1:** Install/launch via the built app; bring an RS3 window to the front.
- [ ] **Step 2:** Open the bold **RaceStudio 3** app menu. Expected: **Import RaceStudio 3 Data…** and **Uninstall RaceStudio 3…** appear above Quit; **Quit** shows ⌘Q.
- [ ] **Step 3:** Click **Import RaceStudio 3 Data…** → Import app launches. Click **Uninstall RaceStudio 3…** → Uninstall app launches.
- [ ] **Step 4:** Confirm ⌘Q still quits RS3 and phase-1 ⌘C/⌘V still work in a text field (no regression).
- [ ] **Step 5:** Record macOS build number + result in the PR; update `CLAUDE.md` "Don't retry" — the "Custom items in Wine's macOS app menu … Not worth it" entry is now SUPERSEDED (done via a single-module source build).

---

## Self-review notes

- **Spec coverage:** menu items (Tasks 1,5,6), launch action (patch methods + Task 2), ⌘Q consolidation (Task 4), build integration (Tasks 0,3,5), on-device (Task 6). ✓
- **Feasibility corrected:** this is a single-module build (`make dlls/winemac.drv` → `winemac.so`) swapped into the prebuilt bundle, NOT a full Wine rebuild — the same proven technique as the bridge's `ws2_32.dll` patch (`installer/bridge/wine-patch/README.md`). Shared toolchain + CI decision.
- **Selector/title consistency:** `wine_rs3ImportData:` / `wine_rs3Uninstall:` / `wine_rs3OpenAuxApp:` and the exact `.app` titles are used identically in the patch, the unit test, and the build-output assertion.
- **Open coordination items:** (1) patch directory — generalize `installer/bridge/wine-patch/` → `installer/wine-patch/` or co-locate; (2) the CI build-vs-commit-blob decision — pick once for both modules.
```
