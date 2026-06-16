# Changelog

All notable changes to **RaceStudio 3 for macOS** (this community installer).

Versions are the upstream **AiM RaceStudio 3** release (e.g. `3.83.20`) plus a
downstream **packaging revision** — `-1`, `-2`, … — that increments each time we
rebuild or repackage the *same* upstream version (new installer features, fixes, or a
fresh notarized DMG). The suffix resets to `-1` when AiM ships a new RaceStudio 3
version, so the weekly auto-updater would cut `vX.Y.Z-1`. This is the Debian/RPM
`upstream-revision` convention. The bundled RaceStudio 3 is unmodified AiM software;
only this installer is versioned here.

Format follows [Keep a Changelog](https://keepachangelog.com/en/1.1.0/).

## [3.83.20-4] — 2026-06-16

### Fixed
- **Wi-Fi setup prompt now actually appears on first launch.** The launcher probed the
  background-helper state with `aim-bridge-ctl status`, but that tool exits non-zero for
  every not-yet-enabled state (`notFound`, `requiresApproval`) and AppleScript's
  `do shell script` treats *any* non-zero exit as an error — so the launcher silently
  bailed before showing the "Set Up Wi-Fi" dialog. The helper was never registered, and
  Wi-Fi found no connected devices. The status/register probes now tolerate the non-zero
  exit, so the setup flow (and its Login Items follow-up) is reachable. SD-card / USB
  import was unaffected.

### Changed
- **"Show RaceStudio 3 Logs" diagnostics** now flag an un-enabled Wi-Fi helper explicitly:
  on macOS 15+ a `bridge daemon` state other than `enabled` prints a note that this is why
  Wi-Fi shows no devices, plus the steps to fix it.

## [3.83.20-3] — 2026-06-16

Native macOS app-menu items and a smoother launch.

### Added
- **Native menu items in RaceStudio 3's own menu bar.** Opening the bold **RaceStudio 3**
  menu (top-left, while RS3 is running) now shows **Import RaceStudio 3 Data…**,
  **Uninstall RaceStudio 3…**, and **Show Logs…** above a ⌘Q **Quit** — each launches the
  matching app, so the controls are reachable without hunting in the AiM folder. Built by
  compiling a small patch into Wine's macOS driver and swapping that one module in.
- **"Show RaceStudio 3 Logs" app.** One click gathers the current logs (run/install logs,
  the Wi-Fi bridge log, and a system-info summary) into a dated folder on your Desktop and
  opens it in Finder — handy for sending diagnostics to support. Also reachable as the
  **Show Logs…** menu item above.

### Fixed
- **Launch no longer looks like a crash.** The Dock icon used to appear, vanish for a few
  seconds, then reappear with the window. It now stays continuously visible until the
  RaceStudio 3 window is up. (The ~3-4s startup itself is RaceStudio 3's own graphics
  initialization and is unchanged.)

### Changed
- The ⌘Q Quit shortcut and the new menu items are now a single from-source Wine driver
  patch; the previous post-build binary patcher is retired.

## [3.83.20-2] — 2026-06-13

First release to ship the Wi-Fi fix, plus several features that had merged since the
initial release but were never cut into a build.

### Added
- **Wi-Fi to AiM devices on macOS 15 (Sequoia) and 26 (Tahoe).** The OS "Local Network"
  privacy gate silently dropped RaceStudio 3's LAN traffic to the dash under Wine — the
  device never appeared. The app now keeps RS3 on loopback (gate-exempt) and relays to the
  real dash through a small root background helper, registered on first launch (one-time
  "Allow in the Background"). Verified end-to-end on a real AiM **MXS** dash.
- **SmartyCam / SD-card import** confirmed working under Wine — insert the card *before*
  opening RaceStudio 3 (or quit and reopen with it in), and video + data import normally.
- **Native Mac keyboard shortcuts** inside RaceStudio 3 — ⌘ acts as Ctrl for the common
  shortcuts (copy/paste/etc.).
- **⌘Q quits** RaceStudio 3 the standard Mac way.

### Fixed
- **Lap-compare video renders at the correct size.** Earlier the second compare video
  shrank to a small box in the corner. RS3's embedded libVLC was falling to GPU video
  outputs that don't work under Wine on Apple Silicon (wined3d can't create a D3D11
  device); the launcher now forces VLC's software (`wingdi`) output, which sizes correctly.
- **Uninstaller** now fully removes the engine, the `/Applications/AiM` apps, the real data
  directory (only with `--remove-data`), and tears down the root Wi-Fi helper.

### Known limitations
- The lap-compare video is software-rendered, so it looks a little soft. Sharp GPU video
  isn't currently possible under Wine on Apple Silicon — the investigation and a real-fix
  plan are in `docs/plans/2026-06-13-sharp-video-vout.md`.
- Connecting AiM devices over **USB** is not supported under Wine. Use Wi-Fi or SD-card
  import.

## [3.83.20-1] — 2026-06-03

Initial public release.

### Added
- **One-click, notarized `.dmg` installer.** Drag RaceStudio 3 to Applications, open once,
  and it sets up a pinned modern Wine + RaceStudio 3 with a live progress bar — no Windows,
  no Parallels, no CrossOver.
- **Standalone Import and Uninstall apps**, shipped beside the main app in
  `/Applications/AiM` (reachable from Finder, Spotlight, Launchpad).
- **Safe data handling** — telemetry lives in `Documents/AIM_SPORT`, relocated with
  copy-if-absent + atomic symlink (never clobbers existing data); iCloud-Documents-sync
  aware so the live database can't be moved off the Mac.
- **Wine app-menu rebranded** to "RaceStudio 3" (not "Wine").
- **Weekly auto-update** that detects a newer AiM RaceStudio 3 release and cuts a new build.
- Versioned DMG filename (`RaceStudio3-<version>.dmg`).
