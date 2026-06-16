# installer/wine-patch — native macOS app-menu items (winemac.so source patch)

RaceStudio 3 runs under Wine, and Wine owns the bold top-left macOS app menu while RS3 is up. That
menu is built in compiled Cocoa inside `winemac.drv`, with no config hook — so the only way to add
items is to patch the source and rebuild that one module. This directory holds that patch and its
build recipe.

## What ships

| File | Role |
|------|------|
| `winemac-native-menu.patch` | diff of `dlls/winemac.drv/cocoa_app.m`: adds **Import RaceStudio 3 Data…**, **Uninstall RaceStudio 3…**, **Show Logs…** menu items above Quit (each `/usr/bin/open`s the matching app in `/Applications/AiM`, `~/Applications/AiM` fallback), and folds the ⌘Q Quit-shortcut remap into source (retiring the old `patch-wine-cmdq.py` binary edit). |
| `build-winemac-so.sh` | builds the patched **x86_64** `winemac.so` from the pinned Wine source and writes it to `build/winemac/x86_64-unix/winemac.so`. |
| `unit-winemac-patch.sh` (in `installer/test/`) | asserts the patch applies to the pinned Wine source and introduces the selectors/titles + the ⌘Q-only mask. SKIPs (77) without `WINE_SRC`. |

The single-module swap is ABI-safe because the from-source module matches the bundled Gcenx Wine
version (`WINE_PINNED_VER`). It exports the same Wine unix-call ABI symbols
(`__wine_unix_call_funcs` / `__wine_unix_call_wow64_funcs`) and links the same frameworks; the build
normalizes its `install_name` to `winemac.so` to match the Gcenx module exactly.

## Why x86_64 / Rosetta (NOT the bridge recipe verbatim)

`installer/bridge/wine-patch/build-wine-dlls.sh` builds **PE** DLLs (ws2_32, wlanapi) with mingw,
which cross-compiles to `x86_64-windows` regardless of the build host — so it configures natively
(arm64 on Apple Silicon CI) and is left untouched.

`winemac.so` is different: it is a **unix host dylib**. It must be **x86_64** to drop into the Gcenx
`osx64` bundle at `lib/wine/x86_64-unix/winemac.so` (that Wine runs under Rosetta). A native build on
an Apple Silicon host yields an `aarch64-unix` module, which is NOT swappable. So `build-winemac-so.sh`
runs the whole `configure` + `make` under `arch -x86_64` and **hard-fails** if the result is not
x86_64 — it can never silently ship a wrong-arch module. This requires Rosetta 2 on an arm64 build
host (`softwareupdate --install-rosetta`). `--without-freetype` is passed because an arm64 Homebrew
has no x86_64 FreeType (which would abort an x86_64 configure) and `winemac.so` links no FreeType.

## CI integration — build in CI (matches the bridge)

Same decision as the bridge's `ws2_32.dll` / `wlanapi.dll`: **build the module in CI, don't commit a
prebuilt blob.** `release-dmg.yml` runs `build-winemac-so.sh` on the `macos-14` runner; `build-apps.sh`
step 1d swaps the result into the bundle (fail-loud under `HARDENED_RUNTIME=1`). Keeping it source-built
means it tracks `WINE_PINNED_VER` automatically on a Wine bump, with no binary to re-cut by hand.

> CI note: the `macos-14` runner is Apple Silicon. The winemac build runs under `arch -x86_64`, so the
> runner must have Rosetta 2 available. If a runner image lacks it, the build fails loudly at the
> arch guard (it does not ship arm64) — install Rosetta in the workflow step before building.

## Local build

```bash
brew install mingw-w64 bison flex          # once
bash installer/wine-patch/build-winemac-so.sh   # -> build/winemac/x86_64-unix/winemac.so
NO_DMG=1 bash installer/build/build-apps.sh      # swaps it into the bundle (step 1d)
```
