> Generated: 2026-06-02 | Token-lean format for LLM context

# Architecture — aim-racestudio3-mac

Free one-click macOS (Apple Silicon) installer for AiM RaceStudio 3. Ships a notarized DMG holding
an `AiM` folder you drag to `/Applications`. Wine-backed; no Windows/Parallels/CrossOver.
Languages: **Bash** (engine), **AppleScript** (the apps), **Python** (build-time asset/patch tools),
**GitHub Actions** (build/release). No package manager.

## Components

```
RaceStudio 3.app (AppleScript applet, RaceStudio3.applescript)
  ├─ Contents/Resources/installer-core.sh + lib/ + pins.env   (the bash ENGINE, embedded)
  ├─ Contents/Resources/wine/                                  (bundled, patched, signed Wine)
  └─ first launch → runs 8 phases → installs engine to ~/Library/Application Support/RaceStudio3
Import RaceStudio 3 Data.app   (applet; embeds engine; calls `installer-core.sh --import`)
Uninstall RaceStudio 3.app     (applet; runs the generated ~/…/RaceStudio3/bin/uninstall.sh)
```
All three ship as siblings in the DMG's `AiM` folder → installed to `/Applications/AiM/`.

## Install flow (8 phases, run by the applet or `installer-core.sh run`)

```
preflight → acquire-installer → download-wine → make-prefix → silent-install
          → relocate-data → make-launcher → done
```
Bundled-Wine mode (the shipped app): `download-wine` is skipped (Wine is in the bundle, passed via
`RS3_WINE_BIN`); `RS3_SINGLE_APP=1`.

## Build → release flow

```
installer/build/build-apps.sh   (macOS only — needs osacompile/codesign/hdiutil/notarytool)
  0 compile applet  1 embed engine  1b bundle Wine  1c patch Wine app-menu name
  2 icon  3 Info.plist  3b build Import/Uninstall applets  4 codesign  5 notarize+staple  6 DMG
        ↓ output
  installer/dist/RaceStudio3-<version>.dmg   (version = RS3_PINNED_VER, e.g. 3.83.20)

.github/workflows/release-dmg.yml      on tag v* (or dispatch) → build+notarize → publish Release
.github/workflows/weekly-rs3-update.yml  Mon 12:00 UTC → if AiM has newer RS3: bump pins, tag, release
```
Tag scheme: `v<RS3 version>` (e.g. `v3.83.20`); the DMG filename + app bundle version match it.

## Data & install locations

| What | Path |
|------|------|
| Apps (RaceStudio 3 + Import + Uninstall) | `/Applications/AiM/` (falls back to `~/Applications/AiM` if `/Applications` unwritable) |
| Engine + Wine + Windows prefix | `~/Library/Application Support/RaceStudio3/` |
| Telemetry (the `user/` tree, symlinked) | `~/Documents/AIM_SPORT/` — or `~/AIM_SPORT/` when iCloud Documents sync is detected |
| RS3 inside the prefix | `C:\AIM_SPORT\RaceStudio3\`, exe `64\AiMRS3-64-ReleaseU.exe` |

## Key invariants / non-obvious facts

- **App-menu name** ("RaceStudio 3" vs "Wine") = `CFBundleName` patched into each Wine unix-loader's
  embedded `__info_plist` at build time (`patch-wine-appname.py`), NOT argv[0]. Survives `--deep` signing.
- **Data safety**: `data_relocate_safe` is copy-if-absent + atomic symlink swap; never clobbers user data; re-entrant after a crash.
- **Quit**: Cmd-Q under winemac sends `WM_QUERYENDSESSION` which RS3 ignores → unreliable. Reliable kill = `wineserver -k`.
- See `codemaps/installer-engine.md` (engine internals) and `codemaps/build-release.md` (build/CI).
