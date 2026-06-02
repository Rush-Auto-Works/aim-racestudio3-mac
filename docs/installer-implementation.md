# Free-Wine installer — Implementation Plan

Concrete build plan for the design in [installer-design.md](installer-design.md). Reviewer
findings are baked in as hard requirements. **Audience is non-technical; ease is everything.**

## Source layout (in the repo)
```
installer/
  src/
    installer-core.sh        # the robust engine — all real logic; runnable standalone + --dry-run
    launcher.sh              # template for ~/Applications/RaceStudio 3.app's executable
    uninstall-core.sh        # uninstall logic
    Installer.applescript    # the friendly face: native dialogs + progress bar, calls core
    Uninstaller.applescript
    pins.env                 # PINNED versions/urls/sizes (sourced by core) — the verified combo
    lib/
      ui.sh                  # osascript dialog/notify helpers (+ plain-echo fallback for --dry-run/TTY)
      net.sh                 # download_verified(), github_latest(), https-only guard, *.partial→mv
      wine.sh                # find_wine_binary(), run_wine() (per-call error handling + watchdog)
      ledger.sh             # step markers + postcondition checks (resume)
      data.sh               # data_relocate_safe() (collision + atomic + iCloud-aware)
      preflight.sh          # macOS/Rosetta/disk/already-running checks
  build/
    build-apps.sh            # osacompile the applets, embed core scripts into the .app bundles
  test/
    dryrun-test.sh           # CI-able: runs installer-core.sh --dry-run, asserts no net/no writes
    scenarios.md             # manual scenario checklist (clean / migrating / interrupt / uninstall)
```

Distributable = `Install RaceStudio 3.app` (+ `Uninstall RaceStudio 3.app`), zipped. README
documents the one-time **right-click → Open** (Gatekeeper, unsigned).

## The `.app` (friendly face)
Build with `osacompile -o "Install RaceStudio 3.app" Installer.applescript`. The applet:
- Shows a **native progress window** using AppleScript globals: `set progress total steps to 8`,
  `set progress completed steps to i`, `set progress description to "…"` — a real macOS bar,
  no extra deps, no Terminal.
- Runs each phase by shelling to the embedded core: `do shell script "…/installer-core.sh <phase>"`,
  advancing the bar after each. The Rosetta phase uses `do shell script … with administrator privileges`.
- Uses `display dialog` for: welcome, the iCloud/collision question(s), any error (with a
  "Show Log" button → `open` the log), and the final done screen (with "Launch RaceStudio 3").
- Embeds `installer-core.sh` + `lib/` + `pins.env` under `Contents/Resources/`; the applet
  resolves them via `path to me`.
- **The core script is the source of truth** and is independently runnable (`installer-core.sh
  run`, `--dry-run`, `--repair`, `--reinstall`, `--latest`) so it's testable without the GUI.

Phases (the 8 progress steps) map to design §Install flow: preflight → acquire-installer →
download-wine → make-prefix → silent-install → relocate-data → make-launcher → done.

## `installer-core.sh` — contract & key functions
Header: `#!/bin/bash` then **targeted** safety (NOT blanket `set -e` around Wine):
`set -uo pipefail`; an `ERR`/`EXIT` trap that logs + (if GUI) signals the applet to show a
dialog; helper `die()`; every Wine call wrapped (see `run_wine`).

Constants (from `pins.env`):
```
WINE_PINNED_URL="https://github.com/Gcenx/macOS_Wine_builds/releases/download/11.9/wine-staging-11.9-osx64.tar.xz"
WINE_PINNED_SIZE=...          # bytes, asserted after download
RS3_PINNED_VER="3.83.20"      # verified-silent version
RS3_PINNED_URL="https://www.aim-sportline.com/.../RaceStudio3-64_38320_..._145224.exe"
RS3_PINNED_SIZE=345795344
APP_SUPPORT="$HOME/Library/Application Support/RaceStudio3"
DATA_DIR_DEFAULT="$HOME/Documents/AIM_SPORT"
```

Functions:
- `ledger_done <step>` / `ledger_check <step>` — markers in `$APP_SUPPORT/state/`; each step's
  check verifies its **postcondition** (e.g. `wine.ok` ⇒ binary globs + `--version` works).
- `find_wine_binary` — `find "$APP_SUPPORT/wine" -type f -name wine -path '*/bin/wine' | head -1`;
  assert found + executable; never hardcode the bundle path.
- `run_wine <args...>` — array argv; exports `WINEPREFIX`, `WINEARCH=win64`,
  `WINEDLLOVERRIDES="mscoree=d;mshtml=d"`, `WINEDEBUG=-all`, `WINEPROFILE`/XDG/`TMPDIR` into the
  install root; runs under `watchdog`; treats Wine's nonzero diagnostics as non-fatal (checks
  the real postcondition instead of `$?`).
- `watchdog <secs> <cmd...>` — background the cmd, sleep-loop, `kill` on timeout (no GNU `timeout`).
- `download_verified <url> <dest> <expected_size>` — HTTPS-only guard; to `<dest>.partial`;
  `curl -fL -C -` only if partial ≤ expected; verify size (and sha if provided); atomic `mv`;
  fallback on **any non-200**.
- `validate_version <s>` / `validate_asset <s>` — strict regex allowlists; reject → use pin.
- `data_relocate_safe` — the dangerous one (below).
- `ui_*` (from lib/ui.sh) — `ui_say`, `ui_ask`, `ui_error`, `ui_progress` — osascript when GUI,
  plain echo when `--dry-run`/no TTY/`NO_COLOR`.

## `data_relocate_safe()` — explicit atomic state machine (the #1 risk)
The round-3 skeptic proved the earlier pseudocode had a non-atomic "move-aside-then-symlink"
window. Implement it as this fully-enumerated machine. **DST is made complete-and-verified
BEFORE `SRC` is ever touched**, the symlink is swapped in via an **atomic rename**, and only
disposable defaults (`SRC.gone`) are ever deleted — so no real data can be lost at any crash
point. `SRC = prefix/drive_c/AIM_SPORT/RaceStudio3/user` (fresh defaults). `DST` = chosen data
dir. Ledger markers carry `SRC/DST` in `state/config.env`.

```
# Re-entrant: branch on observed filesystem state first (RESUME LADDER):
if SRC is symlink->DST: ledger data.ok; return
if SRC.tmplink exists:  mv -f SRC.tmplink SRC (atomic); rm -rf SRC.gone; ledger data.ok; return
if SRC.gone exists AND SRC missing: ln -s DST "SRC.tmplink"; mv -f SRC.tmplink SRC; rm -rf SRC.gone; data.ok; return
# else SRC is a real dir -> (re)run forward path (steps are individually safe to repeat):

# 0. disk check sized by ACTUAL data, not a generic number
need_kb = du -sk "$SRC" | field1 ; mul 1.2
assert avail_kb(volume of DST) >= need_kb           # df -Pk "$DST_parent"

# 1. make DST authoritative AND complete (MERGE — copy-if-absent; never overwrite user data)
mkdir -p "$DST"
for each path under SRC: if not exists in DST -> ditto that file into DST   # ditto, not cp -a
verify: every SRC file now present in DST; du(DST) >= du(SRC); no newly-copied file is zero-length
ledger data.copied                                   # DST now has user data + any schema-required defaults

# 2. atomically replace the SRC dir with a symlink -> DST
mv "$SRC" "$SRC.gone"          # SRC.gone = disposable (everything in it is already in DST)
ln -s "$DST" "$SRC.tmplink"
mv -f "$SRC.tmplink" "$SRC"    # ATOMIC rename: SRC is now the symlink
rm -rf "$SRC.gone"
ledger data.symlinked; ledger data.ok
```
- **Merge semantics** (mercury): copy-if-absent means a *newer* RS3's required default files are
  supplied to `DST` while the migrating user's telemetry is never overwritten. Never `rm -rf DST`.
- **No live smoke-test** (mercury): success = exe exists + valid Mach-O/PE header + silent-install
  OK. Do NOT launch RS3 to "test" (CEF takes 10-30 s under Rosetta → false-fail, and a killed
  mid-init RS3 can write corrupt config into the now-symlinked DST). A `--smoke-test` flag can
  opt into a ≥60 s launch for manual QA only.
- **TCC ordering** (skeptic/kimi): show the "macOS will ask 'Wine wants to access Documents' —
  click Allow" dialog **before** the first Documents-touching Wine call. The symlink round-trip
  probe is **best-effort** (log+warn on timeout; never fatal).
- **iCloud**: `preflight` only *warns* and *offers* `~/AIM_SPORT` (non-synced) if it detects
  Desktop-&-Documents sync; default keep-existing. Detection never drives a destructive action.

## Launcher app (`~/Applications/RaceStudio 3.app`)
osacompile applet (or a `.app` wrapping `launcher.sh`) that:
- Resolves absolute paths (CWD is not its dir).
- Exports `WINEPREFIX`, the globbed Wine binary, log path; runs
  `run_wine "C:\AIM_SPORT\RaceStudio3\64\AiMRS3-64-ReleaseU.exe"` **detached** (no Terminal,
  no `~/.wine`).
- If the engine/prefix is missing, shows "RaceStudio 3 isn't installed — run the installer".

## Preflight specifics
- Rosetta: `arch -x86_64 /usr/bin/true` (Apple Silicon only). Missing → admin osascript install;
  distinguish Cancel / standard-user / failure with distinct dialogs; **hard-stop** before any
  Wine call if unavailable.
- Disk: `df -Pk "$APP_SUPPORT"` parse avail KB; need ≥ ~5 GB; re-check before relocation.
- Already-running: `pgrep -f "AiMRS3-64"` AND a `wineserver` whose `WINEPREFIX` is ours; if so,
  refuse mutate, offer Launch/Cancel. Lockfile `$APP_SUPPORT/state/.lock` around mutating steps.

## Build & packaging (`build/build-apps.sh`)
- `osacompile` both applets; copy `installer-core.sh` + `lib/` + `pins.env` into
  `…app/Contents/Resources/`; `chmod +x` the scripts; set a basic `Info.plist`
  (CFBundleName, identifier, min macOS).
- Optional: drop an icon. Do NOT claim notarization. Zip for distribution.
- README: download → **right-click → Open → Open** (one-time), then the app runs.

## Testing (must pass — design §Test plan)
- `test/dryrun-test.sh`: `installer-core.sh --dry-run` makes **no** network calls and **no**
  writes outside a temp sandbox; asserts path/version/regex logic. CI-able.
- Manual `scenarios.md`: (1) clean install renders clean; (2) migrating user's
  `~/Documents/AIM_SPORT` preserved; (3) kill mid-download / mid-prefix / **mid-relocation** →
  resume, no data loss; (4) uninstall; (5) no-network / GitHub-403 / truncated-download /
  Rosetta-cancel / Intel → friendly dialogs; (6) confirm no `~/.wine` created.

## Phasing (ship order)
1. **`installer-core.sh` + lib/** with `--dry-run` and full robustness (the engine). Test headless.
2. **Verified end-to-end** core run on a clean prefix (real download + silent install + relocate).
3. **`data_relocate_safe` migrating-user + interrupt** tests (the risky path) — get these green
   before any GUI.
4. **Applets** (friendly face) + launcher/uninstaller apps + `build-apps.sh`.
5. **README** free-install section + Gatekeeper screenshot + USB/iCloud caveats.

Build the engine first and prove it; the `.app` is a thin friendly wrapper over a script that
already works.

## Round-2 review resolutions (LOCKED decisions — implement exactly)
1. **Architecture = AppleScript applet, not a shell-script `.app`.** The `.app` is built with
   `osacompile` from `Installer.applescript`. **AppleScript is the parent**; it runs the
   engine via `do shell script "…/installer-core.sh <phase>" …` (hidden subprocess — **no
   Terminal window ever**). The bash core never calls back into a Terminal UI; it returns
   status/text, and AppleScript renders all dialogs. (Resolves the mercury "applet vs
   shell-.app" ambiguity — it is the applet.)
2. **Progress = staged native dialogs for v1; no fake determinate bar.** Between phases the
   applet sets `progress description`/`progress completed steps` (the built-in applet progress
   window, coarse per-phase) **and** shows a short "Working on step N of 8 — this can take a
   few minutes" notice before each long `do shell script`. Do **not** attempt per-byte
   progress from bash (all four reviewers flagged it as unreliable). A real Cocoa/JXA progress
   bar is explicitly **v1.1**. (Resolves codex/gemini/mercury/kimi progress concern.)
3. **Launch smoke-test ordering (codex CRITICAL).** Sequence is: silent install → **`wineserver -k`
   for our prefix** (ensure no live Wine process) → **relocate data** → THEN the optional
   exe smoke-test (launch under watchdog for ~8 s, confirm no immediate crash, then
   `wineserver -k` again before declaring success). Never relocate while an RS3/wineserver
   process holds the prefix. Success gate = exe exists + silent-install OK + smoke-test
   didn't crash; Start-Menu shortcut stays diagnostic-only.
4. **`.app` Gatekeeper is STRICTER than `.command` on macOS 14+ (kimi).** Unsigned `.app`
   bundles may require **System Settings → Privacy & Security → "Open Anyway"** (not just
   right-click→Open). The README/Done dialog must document the exact unlock steps with a
   screenshot. Also **offer a `.command` fallback** in the repo for users who hit a hard
   `.app` block — same core script, documented right-click→Open. (We keep `.app` as the
   friendly default but don't pretend Gatekeeper is frictionless.)
5. **Uninstaller self-delete = detached** `(/bin/sh -c 'sleep 2; rm -rf "$APP"') &` with the
   path passed safely; resolve all paths first, deletes last. (codex/gemini)
6. **`WINEDLLOVERRIDES` exported as a variable**, never inlined unquoted (the `;` would split
   the command). Same for any value containing `;`/spaces. (codex)
7. **"Already running" detection = concrete**: `pgrep -f AiMRS3-64` AND a wineserver whose
   prefix is ours (check via `lsof`/`ps` env or a PID file we write at prefix creation);
   plus a `state/.lock` around mutating steps. Weak guesses are not acceptable. (codex/mercury)
8. **iCloud detection only WARNS and offers a choice** — it never drives a destructive action
   on its own (detection can false-positive). Default keep-existing; user picks the location.
   (codex)
9. **`--dry-run` cannot validate live network pins** (documented limitation) — it validates
   path/version/regex/disk/Rosetta logic only, no fetches. (mercury)
10. **TCC**: first data access pops "**Wine** wants to access Documents" (names Wine, not RS3) —
    documented as a "don't panic, click Allow" note in the Done dialog + README. (kimi/mercury)

## Round-3 resolutions (LOCKED)
11. **Notarized `.app` is the primary deliverable** (user has an Apple Developer account). This
    **retires** the Gatekeeper friction, the `.command` fallback necessity, AND app-translocation
    (`path to me` breakage) that the reviewers flagged — a signed+notarized app just double-clicks.
    Build step: `codesign --deep --force --options runtime --timestamp --sign "Developer ID
    Application: <name> (<TEAMID>)" "Install RaceStudio 3.app"` → zip → `xcrun notarytool submit
    <zip> --apple-id … --team-id … --password <app-specific> --wait` → `xcrun stapler staple
    "Install RaceStudio 3.app"`. Sign the launcher + uninstaller apps too. Keep an **unsigned
    `.command`** in the repo as a source-available fallback, but it's no longer the safety valve.
12. **Persisted phase config** (codex): preflight/acquisition writes `state/config.env`
    (DATA_DIR, flags, installer path, GUI/dry-run) that EVERY `do shell script <phase>` re-sources
    — decisions must survive across the separate phase processes.
13. **Core/applet interaction contract** (codex): in applet mode the core phases are
    **non-interactive** and emit machine-readable signals (e.g. `NEEDS_CHOICE icloud_location`,
    `NEEDS_CONFIRM overwrite`); **AppleScript** renders the dialog, persists the answer to
    `config.env`, and re-invokes the phase. `ui_ask` (osascript) is used ONLY in standalone CLI
    mode — the core never spawns nested dialogs under the applet.
14. **Watchdog kills the whole job** (codex/skeptic): start Wine in its own process group; on
    timeout (or after each Wine phase) run **`WINEPREFIX=… wineserver -k`** (env exported, or it
    no-ops / hits the wrong prefix) **wrapped in the watchdog** (it can hang); verify no
    RS3/wineserver remains for our prefix before continuing.
15. **`already_running` = mandatory PID file** (mercury/skeptic): write our wineserver PID at
    prefix creation; check it (with stale-PID detection). **Remove** the `lsof`/`ps`-env
    alternative (macOS can't read another process's `WINEPREFIX`). Anchor `pgrep -f AiMRS3-64`
    to **our prefix path** so a migrating user's RS3 running inside their **Parallels VM** does
    not false-trigger "already running" and block the install.
16. **`ditto`, not `cp -a`** (codex/kimi/skeptic); **`EXIT` trap only, not `ERR`** (kimi) —
    `die()` exits non-zero and the single `EXIT` handler shows the friendly dialog conditionally;
    avoids `ERR` double-fires on Wine's benign nonzero exits.
17. **AppleScript `do shell script` needs `with timeout of N seconds`** (gemini) for long phases
    (download/install) — the default is 120 s and would abort a slow Wine download.
