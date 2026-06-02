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
- **Cmd-Q to quit RS3**: winemac sends `WM_QUERYENDSESSION`, which RS3 ignores → no reliable quit.
  Reliable kill is `wineserver -k`. Intercepting Cmd-Q needs an Accessibility/Input-Monitoring grant
  (parked at the user's request). The Uninstall app + a future `Quit` app use `wineserver -k`.
- **Trusting `lsappinfo`/`localizedName`** for the menu name (filename-derived, not the menu title).
- **Patching `CFBundleExecutable` to fix the Dock name** ("wine"): doesn't work — macOS derives the
  Dock/process name from the real on-disk loader filename, not the plist. Worse, a `CFBundleExecutable`
  that doesn't match the actual binary breaks LaunchServices icon resolution → blank Dock icon.
  `patch-wine-appname.py` patches `CFBundleName` only. Verified 2026-06-02. Dock "wine" is accepted (like Cmd-Q).

## Gotchas

- **`~/AIM_SPORT` vs `~/Documents/AIM_SPORT`**: on an iCloud-Documents-synced Mac the installer
  deliberately uses `~/AIM_SPORT` (non-synced) so iCloud "Optimize Storage" can't move the live DB.
  This is expected, not a bug (`preflight.sh::icloud_documents_synced`).
- **In-app RS3 updater (msiexec)**: Wine has `msiexec`+`msi.dll` so it launches and likely installs,
  but in-place update while RS3 runs hits locked-file replacement (no Wine reboot) — untested/unreliable.
  Prefer the pin-bump + rebuild path.
- **PIL fallback fonts lack glyphs** like `▸` (renders as tofu in the DMG background) — use ASCII.
- **Tests**: `bash installer/test/run-all.sh` before committing engine changes.
