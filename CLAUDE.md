# aim-racestudio3-mac — project notes for agents

Free one-click macOS (Apple Silicon) installer for AiM RaceStudio 3 (Wine-backed, notarized DMG).
**Read `codemaps/*.md` first** — architecture, the bash engine, and the build/release pipeline live there.
This file is constraints, conventions, and hard-won gotchas only.

## Conventions

- **Releases**: tag `v<RS3 version>` (e.g. `v3.83.20`) on `main`. The tag triggers `release-dmg.yml`
  → build + notarize + publish. The DMG filename and app-bundle version both equal the RS3 version
  (derived from `RS3_PINNED_VER`). Asset is `RaceStudio3-<version>.dmg`.
- **Updating RS3**: don't hand-edit version pins. `weekly-rs3-update.yml` (Mon 12:00 UTC) detects a
  newer AiM release and auto-bumps `pins.env` + tags + releases. To do it manually, run
  `installer/build/check-rs3-update.sh --apply` then tag.
- **The DMG build is macOS-only** (osacompile/codesign/hdiutil/notarytool). It does NOT run on
  Ubicloud/Linux. `release-dmg.yml` uses `macos-14`; the cheap weekly *check* uses `ubicloud-standard-2`.
- **A local `build-apps.sh` run is signed but NOT notarized** (no notary creds locally). Notarized
  artifacts only come from CI (ASC key in secrets) or by setting `NOTARY_PROFILE`/`NOTARY_KEY…`.
- **CodeRabbit findings**: use the `cr-check` skill (or `~/.claude/scripts/cr-check.sh`), never raw
  `gh api` comment parsing. Follow the bot-review loop: green CI **and** `reviewDecision == APPROVED` before merge.
- **End-of-session learnings** for this Rush repo: `session-learnings-rush` skill (PR to the shared KB).

## Hard rules (don't break)

- **Data safety** (`lib/data.sh::data_relocate_safe`): copy-if-absent + atomic symlink swap, fully
  re-entrant. Never make it overwrite an existing user file or `rm -rf` the data dir. The user's data wins.
- **App-menu name** comes from `CFBundleName` patched into each Wine unix-loader's embedded
  `__info_plist` at build time (`patch-wine-appname.py`), NOT argv[0]. Keep step 1c before signing.
- **macOS gotchas**: BSD `stat -f` (not `-c`); Unix socket paths ≤104 chars; writing `/Applications`
  needs admin (engine falls back to `~/Applications/AiM`).

## Don't retry (ruled out, with reasons)

- **NSStatusItem menu-bar helper** (removed): invisible under Bartender / Tahoe. Abandoned.
- **Custom items in Wine's macOS app menu**: `winemac.drv` builds it in compiled Cocoa with no
  config hook; would require rebuilding Wine from source. Not worth it.
- **Cmd-Q to quit RS3**: the native app-menu Quit (`terminate:`) **does reliably quit RS3** — verified
  on device 2026-06-07 (⌘⌥Q quit a running RS3). The old "RS3 ignores `WM_QUERYENDSESSION`" worry
  applies to *forwarding a keystroke into the app*, NOT the AppKit menu item, which terminates the Wine
  process directly. We bind it to the Mac-standard ⌘Q by binary-patching winemac.so's Quit modifier
  mask (`patch-wine-cmdq.py`, build step 1d) — no Accessibility grant needed (the menu owns ⌘Q; no
  global keystroke intercept). `wineserver -k` is still the hard kill used by the Uninstall app.
- **Trusting `lsappinfo`/`localizedName`** for the menu name (filename-derived, not the menu title).
- **Patching `CFBundleExecutable` to fix the Dock name** ("wine"): doesn't work — macOS derives the
  Dock/process name from the real on-disk loader filename, not the plist. Worse, a `CFBundleExecutable`
  that doesn't match the actual binary breaks LaunchServices icon resolution → blank Dock icon.
  `patch-wine-appname.py` patches `CFBundleName` only. Verified 2026-06-02. Dock "wine" is accepted (like Cmd-Q).
- **`DYLD_INSERT_LIBRARIES` to interpose Wine's sockets** (for the WiFi loopback redirect): doesn't
  fire — DYLD insert is **not honored for Rosetta-translated x86_64 processes** (macOS 26.4.1), and the
  Wine unix-loader is x86_64-under-Rosetta. Proven 2026-06-07 via `installer/bridge/test/interpose_rewrite.c`
  (loads into native arm64, never into `arch -x86_64`; independent of signing/hardened-runtime). The
  WiFi redirect (Phase 2) uses a Wine **source patch** instead. See `docs/plans/2026-06-05-wifi-loopback-bridge.md`.
- **win32 `ws2_32` proxy/hook DLL** (to redirect RS3's sockets without rebuilding Wine): no clean
  injection — **Wine doesn't implement `AppInit_DLLs`** (its `user32.dll` has no AppInit code at all),
  and a same-named forwarder `ws2_32.dll` can't reach the builtin (name collision). Verified 2026-06-07
  via `installer/bridge/test/appinit_probe.c`. The Phase 2 redirect is the Wine **source patch**.

## Gotchas

- **`~/AIM_SPORT` vs `~/Documents/AIM_SPORT`**: on an iCloud-Documents-synced Mac the installer
  deliberately uses `~/AIM_SPORT` (non-synced) so iCloud "Optimize Storage" can't move the live DB.
  This is expected, not a bug (`preflight.sh::icloud_documents_synced`).
- **In-app RS3 updater (msiexec)**: Wine has `msiexec`+`msi.dll` so it launches and likely installs,
  but in-place update while RS3 runs hits locked-file replacement (no Wine reboot) — untested/unreliable.
  Prefer the pin-bump + rebuild path.
- **PIL fallback fonts lack glyphs** like `▸` (renders as tofu in the DMG background) — use ASCII.
- **Tests**: `bash installer/test/run-all.sh` before committing engine changes;
  `bash installer/bridge/run-bridge-tests.sh` before committing WiFi-bridge changes.
- **WiFi bridge (macOS 15+ Local Network gate) — WORKS, verified on real MXS dash + macOS 26
  (2026-06-11).** The gate drops the Wine guest's LAN traffic to the dash. The fix needs FOUR
  pieces (all load-bearing; each prior one is necessary-but-insufficient — don't drop any):
  1. **`wlanapi.dll` patch** (`wine-patch/wlanapi-synth-iface.patch`) — Wine's `wlanapi` reports
     zero Wi-Fi interfaces, so RS3 never starts discovery. Present ONE synthetic *connected*
     interface (`WlanEnumInterfaces` + `WlanQueryInterface(current_connection)`).
  2. **`ws2_32.dll` outbound redirect** (`wine-patch/ws2_32-localnet.patch`) — RS3 addresses
     aim-ka discovery to **`0.0.0.0:36002`** under Wine (NOT `10.0.0.255`/gateway). Redirect both
     `10.0.0.0/24` and `0.0.0.0:36002` → `127.0.0.1`, remap port `36002`→`36003`.
  3. **`ws2_32.dll` inbound source-rewrite** — the relay replies from `127.0.0.1:36003`; RS3
     ignores replies not from the dash, so rewrite the recv source back to `10.0.0.1:36002`.
  4. **root `SMAppService` daemon `aim-bridge`** — listens `127.0.0.1:36003`(UDP)/`:2000`(TCP),
     relays to `dash:36002`/`:2000` (registered by `aim-bridge-ctl`; one-time Login Items approval).
  Both DLLs built in CI by `wine-patch/build-wine-dlls.sh`, swapped by `build-apps.sh` step 1e.
  Wine loads PE builtins from the BUNDLE `lib/wine/`, not the prefix — the launcher refreshes the
  prefix copies of BOTH DLLs on upgrade (Wine only seeds them at prefix-creation). Full detail:
  memory `wifi-bridge-COMPLETE`, `docs/plans/2026-06-05-wifi-loopback-bridge.md`, `installer/bridge/README.md`.
- **Lap-compare video = embedded libVLC 3.0.9.2; ship the `wingdi` vout.** RS3 plays compare/
  SmartyCam video through embedded libVLC. Under Wine on Apple Silicon, `wined3d` can't make a
  D3D11 device (so VLC's `direct3d11` vout never opens), the `direct3d9` vout shrinks the 2nd
  compare video on a shared fake device, and the OpenGL vout corrupts the frame. Only `wingdi`
  (GDI) renders correctly at the right size (software-scaled → soft, accepted). The launcher
  hygiene (`RaceStudio3.applescript` + generated `bin/launch.sh`) disables the GPU vout plugins
  (`libdirect3d11/d3d9/gl/glwin32/wgl_plugin.dll`) in the prefix so VLC falls to wingdi —
  idempotent, re-applies after an RS3 in-app update. Sharp-GPU-video is NOT a config fix (libVLC
  ignores `vlcrc`, takes no options; the d3d11 vout bails upstream of D3D needing dcomp, so DXVK
  AND DXMT can't help). Full detail + the real-fix plan: memory `rs3-video-is-libvlc`,
  `docs/plans/2026-06-13-sharp-video-vout.md`.
- **SmartyCam SD-card import WORKS; card SWAP needs an RS3 restart (accepted, not fixable).**
  RS3 reads a SmartyCam 3 card under Wine with no code changes — insert it before launch (startup
  scan) OR while running (Wine's mountmgr broadcasts `DBT_DEVICEARRIVAL`; RS3's `MyDeviceChange`
  rescans). The one limitation: pull card A, insert card B → RS3 still shows A. Root cause is
  inside RS3's closed binary — it caches the card **by drive letter** (`L:`), ignores
  `DBT_DEVICEREMOVECOMPLETE`, and dedups a same-letter re-insert. Wine is blameless: its `send_notify`
  (`dlls/mountmgr.sys/device.c`) broadcasts BOTH arrival and removal, Windows-identical
  (`flags=DBTF_MEDIA`), and RS3 receives both (verified 2026-06-13). Not cleanly fixable: a userspace
  process can't inject the broadcast (only the mountmgr driver host can), and the only Wine lever
  (assign a fresh letter per card) is invasive + leaky. **Don't re-litigate.** Full detail: memory
  `smartycam-sd-import-works`.
