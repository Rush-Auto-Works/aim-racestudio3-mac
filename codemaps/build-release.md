> Generated: 2026-06-02 | Token-lean format for LLM context

# Build & Release — `installer/build/` + `.github/workflows/`

macOS-only build (Apple tooling: osacompile, codesign, hdiutil, iconutil, sips, notarytool).
Cannot run on Linux/Ubicloud.

## build-apps.sh — steps

| # | Step | Notes |
|---|------|-------|
| 0 | compile `RaceStudio3.applescript` → `$APP` | `RaceStudio 3.app` |
| 1 | embed engine | ditto `installer-core.sh` + `lib/` + `pins.env` into Resources |
| 1b | bundle Wine | extract pinned tarball (cache `/tmp/claude/wine11.tar.xz`); drop gecko+mono (~290 MB) |
| 1c | **rebrand Wine app-menu** | `patch-wine-appname.py` rewrites `CFBundleName` in every `*-unix/wine` loader; fails if zero patched |
| 2 | icons | `build_icns` runs `compose-icon.py` 3× → `rs3.icns` (plain), `rs3-import.icns` (badge), `rs3-uninstall.icns` (badge) |
| 3 | Info.plist | `CFBundleName`/version (= `RS3_PINNED_VER`); delete `CFBundleIconName` droplet quirk |
| 3b | Import/Uninstall applets | osacompile siblings in `$DIST`; embed engine into Import; `brand_applet` applies the badged icns + id/version, deletes `CFBundleIconName` |
| 4 | codesign | non-hardened `--deep` (local) OR `HARDENED_RUNTIME=1` per-file + entitlements (notarizable); signs all 3 apps |
| 5 | notarize+staple | each app + DMG individually (offline Gatekeeper). `notarize_staple` rc 2 = no creds (ok), else fail build |
| 6 | DMG | stage `AiM` folder (3 apps) + `/Applications` symlink + bg; Finder layout; `RaceStudio3-<VERSION>.dmg` |

Key vars: `VERSION` ← `RS3_PINNED_VER` (override `RS3_VERSION`); `VOL="RaceStudio 3"` (mount label);
`DMG="$DIST/RaceStudio3-${VERSION}.dmg"`. Modes: `SKIP_SIGN=1` · `NO_DMG=1` · `NO_TIMESTAMP=1` ·
`HARDENED_RUNTIME=1` · `NOTARY_PROFILE=` / `NOTARY_KEY+NOTARY_KEY_ID+NOTARY_ISSUER` (ASC API key) / `NOTARY_APPLE_ID+NOTARY_PASSWORD`.

## Python helpers (`/tmp/rs3-build-venv`, Pillow)

| File | Role |
|------|------|
| `patch-wine-appname.py <loader> [name]` | Patch `CFBundleName` in the loader's Mach-O `__TEXT,__info_plist` (fixed-size section: strips XML indent, pads). Idempotency scoped to the `CFBundleName` key. |
| `compose-icon.py <logo> <out> [none\|import\|uninstall]` | 1024² app icon (white rounded tile + RS3 wordmark). Optional badge: `import` = bottom-left orange file→RS3, `uninstall` = bottom-left red trash. |
| `compose-dmg-bg.py <logo> <out>` | DMG background ("Drag the AiM folder into Applications"). PIL fallback font lacks `▸` → use ASCII. |
| `check-rs3-update.sh [--apply]` | Scrape AiM page; max `RaceStudio3-64_<vercode>_*.exe` (38320→3.83.20); `--apply` downloads, hashes, rewrites pins.env. |

## pins.env (source of truth)

`RS3_PINNED_VER/FILE/URL/SIZE/SHA256` · `WINE_PINNED_*` · `APP_SUPPORT` · `DATA_DIR_DEFAULT`
(`~/Documents/AIM_SPORT`) · `DATA_DIR_NONSYNCED` (`~/AIM_SPORT`) · `APPS_DIR=/Applications/AiM` ·
`RS3_REL_USER=AIM_SPORT/RaceStudio3/user` · `RS3_REL_EXE`.

## Workflows

| File | Trigger | Runner | Does |
|------|---------|--------|------|
| `release-dmg.yml` | push tag `v*`, `workflow_dispatch` | `macos-14` (GitHub-hosted) | build+notarize; publish Release ONLY on `refs/tags/*`. DMG referenced via `installer/dist/*.dmg` glob. |
| `weekly-rs3-update.yml` | cron Mon 12:00 UTC, dispatch | `ubicloud-standard-2` | `check-rs3-update.sh --apply`; if newer: commit pins to main, tag `v<ver>`, `gh workflow run release-dmg.yml --ref <tag>` (GITHUB_TOKEN tag pushes don't auto-trigger → explicit dispatch is the single build). |

Secrets (release-dmg): `DEVELOPER_ID_CERT_P12` `DEVELOPER_ID_CERT_PASSWORD` `KEYCHAIN_PASSWORD`
`ASC_KEY_P8` `ASC_KEY_ID` `ASC_ISSUER_ID`; optional `CODESIGN_IDENTITY` `RS3_LOGO_B64`.
`actions/checkout` pinned to SHA (v4.3.1) in weekly workflow.
