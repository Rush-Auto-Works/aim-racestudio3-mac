# Free-Wine one-click installer — Design (v2, post-review)

Status: DESIGN, revised after a 5-reviewer debate (codex, gemini, mercury, kimi, Opus
skeptic). This version addresses every CRITICAL/MAJOR finding. Implementation steps live
in [installer-implementation.md](installer-implementation.md); the build prompt is
[../INSTALLER-BUILD-PROMPT.md](../INSTALLER-BUILD-PROMPT.md).

## North star
**Ease of installation is everything. The audience is NOT technical** (racers, not
programmers). The user should double-click one thing, answer at most one or two plain
questions in native macOS dialogs, watch a friendly progress bar, and end with RaceStudio 3
open. They should never see a Terminal full of scrolling text, and they must never lose data.

## What it installs (free, no CrossOver, no Homebrew, no sudo except one-time Rosetta)
RaceStudio 3 under a pinned, **verified** modern Wine (Gcenx Wine 11.9 staging), which
renders RS3 cleanly (Wine ≥10 fixes the CEF text bug; old Wine is garbled).

## Deliverable: a `.app`, not a `.command`
A double-clicked `.command` opens Terminal (intimidating) **and** is Gatekeeper-quarantined
with no in-band way to fix itself. Instead ship **`Install RaceStudio 3.app`**:
- A minimal app bundle whose executable is the robust installer shell script.
- All user-facing communication is **native macOS dialogs** via `osascript`
  (`display dialog`, and a determinate progress via a lightweight AppleScript progress
  window or staged dialogs) — friendly, non-scary, on-brand.
- Detailed technical logging still goes to a log file (for support), not the user's face.
- **First-launch Gatekeeper: SOLVED via notarization.** We have an Apple Developer account, so
  the app is **codesigned (Developer ID Application, hardened runtime) + notarized + stapled** —
  it **double-clicks with no Gatekeeper prompt at all**. This also avoids **app translocation**
  (which would otherwise break the applet's `path to me` resolution of its embedded core script).
  An unsigned `.command` stays in the repo as a source-available fallback, but is no longer the
  primary path. (See implementation doc §11 for the codesign/notarytool/stapler steps.)
- A matching **`Uninstall RaceStudio 3.app`** (also signed + notarized).

## Layout (NATIVE — chosen)
| What | Where |
|------|-------|
| Installer / Uninstaller (what the user downloads & double-clicks) | wherever they put it (e.g. Downloads) |
| Launcher app | `~/Applications/RaceStudio 3.app` |
| Wine engine + Windows prefix + logs + installer cache + **state ledger** | `~/Library/Application Support/RaceStudio3/` |
| RS3 **user data** (configs, profiles, database, sessions) | `~/Documents/AIM_SPORT/` (default; relocatable if iCloud risk — see below) |

Inside `~/Library/Application Support/RaceStudio3/`: `wine/`, `prefix/`, `installer/`,
`logs/`, `state/` (per-step completion ledger), `bin/` (launch/uninstall helpers the app
bundles call). `~/Applications` is `mkdir -p`'d (it doesn't exist by default).

## Pinning & acquisition (reviewers: do NOT default to "latest")
- **Wine:** default = **pinned, verified** `wine-staging-11.9-osx64.tar.xz` with its recorded
  **size** (and sha256 if obtainable). `--latest` is opt-in and prints "unverified". After
  extraction, **glob** for the binary (`find … -path '*/bin/wine' -name wine`) — never
  hardcode the `Wine Staging.app/...` path (it already changed once: `wine` vs `wine64`).
- **RS3 installer:** default = the **verified** version (pin filename + size). Auto-download
  from AiM is best-effort over **HTTPS only**; on any failure, fall back to: look in
  `~/Downloads`, then open the AiM page and wait for the user to download, then re-detect.
- **All scraped/fetched strings** (version, asset name) are **validated against strict
  regexes** before touching a filename, URL, or command — e.g. version `^[0-9]+(\.[0-9]+){1,3}$`,
  asset `^wine-(staging|devel|stable)-[0-9.]+-osx64\.tar\.xz$`. Reject otherwise. Use **array
  argv**, never built command strings. No `eval`.
- **Downloads** go to `*.partial`, are **size-verified**, then atomically `mv`'d into place.
  `curl` only resumes after confirming the partial matches expected size; otherwise restart.
  GitHub API / AiM fetch falls back on **any non-200** (covers 403 rate-limit on shared NAT),
  not only connection failure.

## Install flow (inside the app)
1. **Welcome dialog** — one paragraph: what it does, where files go, "~10 min, needs internet".
2. **Preflight:**
   - macOS version check.
   - **Rosetta 2** (Apple Silicon only; skip on Intel): detect via `arch -x86_64 /usr/bin/true`.
     If missing → admin GUI install
     (`osascript … do shell script "softwareupdate --install-rosetta --agree-to-license" with administrator privileges`).
     Handle **Cancel**, **standard (non-admin) user** ("ask an admin to run: `softwareupdate --install-rosetta`"),
     and **install failure** with a clear hard-stop dialog — do not proceed to Wine calls.
   - **Disk space** ≥ ~5 GB (Wine tarball + extracted Wine + cached installer + 785 MB tree +
     prefix + transient 2× user-data during relocation); re-check before relocation.
   - **Already-installed / already-running** detection: if a live `wineserver` or `AiMRS3-64`
     process is using our prefix, refuse mutating actions and offer Launch/Cancel. Offer
     Reinstall / Repair / Cancel for an existing install.
3. **Acquire RS3 installer** (pinned; see Pinning).
4. **Download + extract Wine** (pinned; `*.partial`→verify→`mv`; `xattr -dr com.apple.quarantine`
   scoped to the `wine/` dir only; glob for the binary; assert found + executable).
5. **Create prefix:** `WINEPREFIX=…/prefix`, `WINEARCH=win64`,
   `WINEDLLOVERRIDES="mscoree=d;mshtml=d"` (skip the Mono/Gecko download prompt/hang —
   RS3 is native+CEF, doesn't need them), `WINEDEBUG=-all`, redirect XDG/temp caches into the
   install root, then `wine wineboot --init`. **Per-Wine-call error handling** (no blanket
   `set -e` around Wine — it returns nonzero for diagnostics); use a **watchdog** (background
   process + timed `kill`; macOS has no `timeout`).
6. **Silent install:** `wine "<installer>" /exenoui /qn` under the watchdog, then
   **`wineserver -k` (kill all Wine processes for our prefix)** so nothing holds the prefix
   open before relocation. Initial success = main exe exists + silent-install returned OK
   (Start-Menu shortcut is diagnostic only, never the gate). The **live exe smoke-test happens
   AFTER relocation** (step 7), under the watchdog for a few seconds, then `wineserver -k`
   again — never launch RS3 while we're about to move its data. On timeout/failure → clear
   dialog pointing at the log + the troubleshooting doc.
7. **User-data location (the dangerous step — see Data Safety):** resolve `~/Documents/AIM_SPORT`
   collisions safely, relocate atomically, symlink, verify round-trip.
8. **Create** `~/Applications/RaceStudio 3.app` (native launcher) + `Uninstall RaceStudio 3.app`.
   Launcher exports `WINEPREFIX`/Wine path/log paths (so it never creates `~/.wine`), resolves
   its own absolute paths, and runs RS3 detached (no lingering Terminal).
9. **Optional data import** (opt-in dialog): reuse `scripts/port-data-from-parallels.sh` to pull
   from a running Parallels VM. Isolated from the success path; fail-closed if `prlctl` absent.
10. **Done dialog:** exact locations created, a **WiFi-yes / USB-no** hardware note, how to
    launch, how to uninstall; offer **Launch now**.

## Data Safety (step 7 — the #1 review concern)
The audience is people **migrating** from Parallels/CrossOver, so `~/Documents/AIM_SPORT`
**often already exists with their real telemetry.** Rules:
- **Never clobber.** If `~/Documents/AIM_SPORT` exists and is non-empty, treat it as
  **authoritative** (it's the user's real data); the fresh prefix's `user/` is just defaults.
  Move the fresh defaults aside and symlink the prefix to the existing Documents data. If
  there's any doubt, **back up aside** to `~/Documents/AIM_SPORT.backup-<timestamp>` and tell
  the user — never silent overwrite.
- **Crash-atomic + resumable:** copy prefix `user/` → Documents → **verify** → create symlink
  → **only then** delete the source. Each state is re-detectable on a re-run (see Ledger).
  Never leave a window where the only copy could be lost.
- **iCloud risk:** detect Desktop-&-Documents iCloud sync (check `~/Library/Mobile Documents`
  / `brctl` presence / the Documents path being managed). If on, **warn** the user that
  iCloud "Optimize Mac Storage" can evict the live database and offer to place data outside
  the synced tree (e.g. `~/AIM_SPORT`) instead — default to the safe choice but let them keep
  Documents. Document the TCC prompt (macOS will ask "Wine wants to access Documents" — they
  must Allow, and it names *Wine*, not RaceStudio 3).
- Verify the symlink round-trips under Wine (write a file via `C:\AIM_SPORT\RaceStudio3\user`,
  confirm it appears in the Documents folder) and that it doesn't collide with RS3's own
  `.lnk` data-redirect (`data.lnk`).

## Migration flows (bring data from another PC / Parallels)
The audience is migrating, so offer several dead-simple ways to bring data over — **all funnel
through the same copy-if-absent MERGE** (never overwrite, never clobber; see Data Safety):
1. **Auto from a running Parallels VM** — `scripts/port-data-from-parallels.sh` (opt-in dialog
   during install, or run anytime). Finds the `user/` tree + recent `.xrk` via a Parallels share.
2. **Drag-and-drop a folder** — an **`Import RaceStudio 3 Data.app`** droplet (AppleScript
   `on open`): drag the **`AIM_SPORT`** folder (or its `RaceStudio3\user` subfolder) — from
   another PC, a USB stick, a backup, or a Parallels shared folder — onto it and it merges
   configs/profiles/database/sessions into the data dir. Also accepts a **`.zip`** (unzips to a
   temp dir first) and loose **`.xrk`** files (→ `data/<date>/`).
3. **"I have a folder" picker** — same import via a `choose folder` dialog inside the installer's
   optional import step, for users who prefer clicking to dragging.
4. **Manual** — README documents the exact Mac path of the data dir so users can drop files in
   via Finder; RS3's built-in Import/Export still covers one-offs.

Getting the folder OUT of the source: from a **Windows PC**, copy `C:\AIM_SPORT\RaceStudio3\user`
(plus any external data folder) to USB/network/cloud, then drag it in. From **Parallels**, use
the auto script, or enable a shared folder and drag the `user` folder to the Mac. Every path
shows a summary of what was imported and never overwrites existing user data.

## Idempotency / resume — a real ledger
`~/Library/Application Support/RaceStudio3/state/` holds a marker per completed step
(`rosetta.ok`, `wine.ok`, `prefix.ok`, `installed.ok`, `data.ok`, `launcher.ok`). Each step
checks **its own postcondition** (not just "target exists"): e.g. `wine.ok` only if the
binary globs + runs `--version`; `installed.ok` only if the exe launches. A truncated
`wine/` or half-moved `user/` is detected and redone, not skipped. `--repair` re-runs from
the first failed postcondition; `--reinstall` wipes engine+prefix (never the Documents data
without explicit confirm).

## Robustness rules (reviewer-driven)
- **No blanket `set -e`** around Wine/spinners/`read`/grep — guard each with explicit checks
  or `|| true`; trap `ERR`/`EXIT` → friendly dialog + log path. Clean up watchdog/spinner PIDs.
- **macOS-native only:** no `jq`/`gh`/GNU `timeout`/Homebrew. Parse JSON with `/usr/bin/python3`
  or `plutil -convert`. Use BSD flags (`df -Pk`, BSD `stat`, `du`). Provide watchdog for timeout.
- **Disk check on the correct volume** (`df -Pk "$APP_SUPPORT"`), re-checked before relocation.
- **Containment is best-effort, not absolute:** Wine *will* touch `~/Library/Caches` etc.;
  set `WINEPREFIX`/XDG/`TMPDIR` into the install root to minimize stray writes, but don't
  promise zero external writes. The uninstaller documents what may remain.
- **Launcher/uninstaller use absolute paths** (a double-clicked app's CWD is not its dir) and
  must not delete themselves mid-run (resolve paths, deletes last).
- **`--dry-run`** mode: validate path resolution, disk, Rosetta detection, version pins — no
  network, no writes — so the script is testable offline / in CI.

## Uninstall
`Uninstall RaceStudio 3.app`: confirm → remove `~/Library/Application Support/RaceStudio3` +
`~/Applications/RaceStudio 3.app` + itself (paths resolved first). **Ask separately** before
removing `~/Documents/AIM_SPORT` (their data; default = keep). Note that Rosetta (if we
installed it) is system-shared and left alone, and that minor Wine caches under
`~/Library/Caches` may remain. Print exactly what was removed.

## Test plan (must pass before shipping — see implementation doc for scripts)
1. **Clean machine** (no prior install, no `~/Documents/AIM_SPORT`): unattended success; RS3
   launches and **renders clean**.
2. **Migrating user** (pre-existing `~/Documents/AIM_SPORT` with data): data is **preserved**
   (backed up / treated authoritative), never clobbered.
3. **Containment-ish:** no `~/.wine`; engine/prefix only in Application Support; data only in
   the chosen location.
4. **Interrupt tests:** kill mid-Wine-download, mid-prefix-init, **mid-relocation** → re-run
   resumes correctly with no data loss.
5. **Uninstall** removes engine + launchers; offers to keep/remove data; leaves nothing else
   of ours (besides documented caches / system Rosetta).
6. **Unhappy inputs:** no network, GitHub 403, truncated download, missing installer,
   Rosetta-cancelled, standard-user, Intel Mac → clear dialogs, no cryptic Wine errors.
7. **`--dry-run`** passes offline.

## Known limitations to state in the UI/README
- **USB device connection does not work** (Wine USB passthrough); WiFi does. Say so in the
  Done dialog and README.
- First launch needs a one-time **right-click → Open** (Gatekeeper, unsigned).
- iCloud "Optimize Storage" + a Wine-written database don't mix; we warn and offer an
  alternative location.

## Decisions
- **`.app` with native dialogs** (not a raw `.command`) — ease + avoids scary Terminal.
- **Pin verified Wine 11.9 + verified RS3 version**; `--latest` is opt-in & flagged unverified.
- **Documents data: never clobber, atomic relocate, iCloud-aware**, default keep-existing.
- **Real step ledger** for resume; `--dry-run` for testing.
