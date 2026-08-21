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

## [Unreleased]

- WiFi bridge now supports all three AiM dash gateway IPs (`10.0.0.1`, `11.0.0.1`, and
  `12.0.0.1`). The relay resolves the dash IP from the Mac's network state, and the `ws2_32`
  redirect covers all three dash subnets.

## [3.83.39-3] — 2026-08-03

**Fixes the satellite track map showing blank (white) in RaceStudio 3.**

- **The track-view map background now renders.** RaceStudio 3's embedded browser (Chromium 66)
  couldn't present its GPU-composited frames to the Wine window, so the map panel stayed white
  even though the tiles were loading. Launching with GPU compositing disabled — rasterization
  stays on — lets the frames through, and the map centers and pans normally. Fixes #37.

## [3.83.39-2] — 2026-08-02

**Installing a newer version of this app now actually updates RaceStudio 3.**

- **A newer DMG now replaces the RaceStudio 3 you already have.** Before this, it didn't. The
  installer remembered the file it downloaded the first time and never checked which version that
  file was, so it reinstalled the copy you already had. If you installed 3.83.39-1 over an older
  setup, you are still on the older RaceStudio 3. Open the app once and it offers to bring you up
  to date.
- **You get an update prompt instead of the first-run welcome.** It says the download is about
  350 MB and that your settings and telemetry are left alone. "Not Now" just opens RaceStudio 3.
- **Nothing ever puts RaceStudio 3 back to an older version.** If RaceStudio 3 updated itself past
  the version this app ships, it stays where it is.
- **"Show RaceStudio 3 Logs" now reports the version you are running.** It used to report the
  version this app expected rather than the one installed, which is how this went unnoticed. It
  shows both now, and flags a mismatch.
- **"Reinstall" reinstalls the current version**, not the one it had cached.
- **If you download the installer yourself, it gets checked first.** Whether you pick it in the
  dialog or leave it in your Downloads folder, it is used only if it is exactly the file this app
  expects.

## [3.83.39-1] — 2026-07-31

**Fixes a freeze when you clone or import a configuration, and updates RaceStudio 3 to 3.83.39.**

- **The Windows environment no longer has a `Z:` drive.** Wine points `Z:` at the root of your Mac
  and reports it as a hard disk. After you clone or import a configuration, RaceStudio 3 scans every
  hard disk it can find, and it follows folder aliases with no limit on depth. Plenty of Mac apps
  ship an alias that points back up their own folder tree, and once the scan walks into one it never
  walks back out. The path RS3 is building just keeps growing until it exceeds the length macOS
  permits. Every file operation then fails, RS3 retries, and the app stops responding with a CPU
  core pinned while `run.log` fills up with `wineserver: file_set_error() can't map error: File name
  too long`. The one that caught us was `/Applications/calibre.app`: it bundles a Qt helper app
  whose `Frameworks` alias points straight back at calibre's own `Frameworks` folder. New installs
  never get the drive, and existing ones lose it the next time you launch RaceStudio 3 or import
  data, so there's no need to reinstall. If you had deliberately pointed `Z:` at a specific folder,
  that mapping is left alone; only the one aimed at the root of your Mac is removed. Fixes #32.

  Nothing you can reach today goes away. Your home folders are already mounted in the Windows
  environment as `C:\users\<you>\Desktop`, `Documents`, `Downloads` and so on, and every external
  drive still gets its own letter, so exporting to the Mac and reading a SmartyCam card work the
  same as before. What you lose is browsing to system paths like `/usr` from RaceStudio 3's file
  picker, which isn't something you'd do with race data anyway.

- **RaceStudio 3 updated to 3.83.39** (from 3.83.26). AiM had also quietly replaced the 3.83.26
  installer at its original download URL with a different file, which broke our checksum check.
  Moving to 3.83.39 sorts that out too.

## [3.83.26-3] — 2026-07-21

**Fixes a track-map freeze (unbounded memory growth) in RaceStudio 3.**

- **GDI+ flatten-loop guard.** RS3's track-map view can draw a marker built from a degenerate
  (NaN/Infinity) ellipse coordinate. Native Windows GDI+ tolerates that input; Wine's
  `GdipFlattenPath` Bezier flattener (`flatten_bezier` in `dlls/gdiplus/graphicspath.c`) never
  converges on a non-finite control point — its "flat enough" checks are `<=` comparisons, which
  are always false against NaN — so it allocates subdivision nodes forever. RSS climbs roughly
  300 MB/s to tens of GB with one CPU core pegged, which reads as a freeze until the process is
  killed or the Mac runs out of memory. Fixed with a small patched `gdiplus.dll` (source patch,
  same one-module pipeline as the WiFi bridge's `ws2_32`/`wlanapi` DLLs): a non-finite control
  point is now treated as flat (straight line to the segment's existing endpoint, no
  subdivision), plus a hard cap on total subdivision nodes as a second line of defense.
  Fixes #29 and #30.

## [3.83.26-2] — 2026-06-23

**Ships a `.pkg` installer (with auto-launch) and fixes the uninstaller.**

- **Uninstaller now removes `/Applications/AiM`.** The generated `uninstall.sh` deferred the folder
  removal with `( sleep 2; rm -rf "$APPS" ) &`, but that detached subshell is reaped when the admin
  `do shell script` returns — so the AiM folder was left behind. Remove `$ROOT` and `$APPS`
  synchronously instead (the `--remove-data` logic and the aim-bridge `launchctl bootout` are
  preserved). Safe to delete the folder containing the running Uninstall app: the admin shell is a
  separate root process, and macOS keeps the launched applet running off its open executable.
- **New `.pkg` alongside the DMG.** `build-apps.sh` builds a component package
  (`RaceStudio3-<ver>-<rev>.pkg`, the four apps → `/Applications/AiM`) for MDM deployment
  (Mosyle/Jamf InstallApplication). A `postinstall` script auto-launches RaceStudio 3 in the console
  user's session on interactive installs (silent for unattended/MDM pushes). Signed with a Developer
  ID Installer cert + notarized when `DEVELOPER_ID_INSTALLER_CERT_P12` is configured; otherwise
  emitted unsigned (still MDM-deployable). `release-dmg.yml` imports the optional Installer cert and
  publishes the `.pkg` asset.

## [3.83.20-5-usb1] — 2026-06-17

**Experimental prerelease — USB device support (Wi-Fi/SD users don't need this).** First build that
can talk to AiM USB devices under Wine, aimed at the USB-only PDM (which has no Wi-Fi or SD-card
path). Not yet confirmed against real AiM hardware — please test and report back.

> **Install clean to test USB.** USB only activates on a freshly created Windows environment, so
> uninstall any existing RaceStudio 3 first (AiM ▸ Uninstall), then install this build. Upgrading
> in place will not enable USB. Wi-Fi and SD-card import are unchanged either way.

### Added
- **USB (WinUSB) support for AiM devices.** AiM USB devices are vendor-class WinUSB (e.g. the PDM).
  The bundled Wine shipped without libusb, so its USB bus driver was missing entirely. This build
  rebuilds Wine's `wineusb` bus driver against libusb (plus a bundled x86_64 libusb) so RaceStudio 3
  can enumerate and open AiM USB devices. Verified on the Mac side (Wine enumerates host USB through
  libusb); the final RaceStudio-3-to-device handshake is what this prerelease is testing.

## [3.83.20-4] — 2026-06-17

A Wi-Fi discovery fix found with the new diagnostics: AiM devices now appear over Wi-Fi
on dashes that reply from an ephemeral port.

### Fixed
- **Wi-Fi devices that replied from an ephemeral port were invisible.** The background helper
  accepted the dash's discovery reply only if it came from the exact port the Mac sent to
  (`36002`). Real AiM dashes answer from an *ephemeral* source port (e.g. `49861`), so every
  reply was silently dropped and RaceStudio 3 listed no connected device — even though the Mac
  was on the dash's Wi-Fi and the dash was answering. The helper now accepts any reply from the
  dash's IP regardless of source port (it still ignores other senders). First confirmed on a
  user's dash that the previous build, verified on an MXS, did not cover.
- **Diagnostics no longer mislabel a patched build as "STOCK".** The "Show RaceStudio 3 Logs"
  component check used `strings`, which ships with the Xcode Command Line Tools and is absent on
  a typical user's Mac — so it silently reported every Wi-Fi/menu component as un-patched. It now
  reads the binaries with `grep`, which is always present, so the report is accurate.

## [3.83.20-3] — 2026-06-16

Native macOS app-menu items, a smoother launch, and a Wi-Fi first-launch fix.

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
- **Wi-Fi setup prompt now actually appears on first launch.** The launcher probed the
  background-helper state with `aim-bridge-ctl status`, but that tool exits non-zero for
  every not-yet-enabled state (`notFound`, `requiresApproval`) and AppleScript's
  `do shell script` treats *any* non-zero exit as an error — so the launcher silently
  bailed before showing the "Set Up Wi-Fi" dialog. The helper was never registered, and
  Wi-Fi found no connected devices. The status/register probes now tolerate the non-zero
  exit, so the setup flow (and its Login Items follow-up) is reachable. SD-card / USB
  import was unaffected.
- **Launch no longer looks like a crash.** The Dock icon used to appear, vanish for a few
  seconds, then reappear with the window. It now stays continuously visible until the
  RaceStudio 3 window is up. (The ~3-4s startup itself is RaceStudio 3's own graphics
  initialization and is unchanged.)

### Changed
- The ⌘Q Quit shortcut and the new menu items are now a single from-source Wine driver
  patch; the previous post-build binary patcher is retired.
- **"Show RaceStudio 3 Logs" diagnostics** now capture the whole Wi-Fi picture so a single log
  bundle pinpoints any connection problem: the bridge-helper state (with a fix hint when it's
  not enabled), whether the patched Wi-Fi DLLs are active in both the app bundle and the Wine
  prefix (plus a bundle check of the menu driver), and the live network context — Wi-Fi SSID,
  the Mac's IP, and the route / reachability to the dash. The background helper and the patched
  `ws2_32`/`wlanapi` now log each step of dash discovery (helper relay traffic + the in-Wine
  redirect), so it's clear whether RS3 is sending, the dash is reachable, and the dash is replying.

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
