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

## USB (WinUSB) support — `wineusb.so` + libusb (`build-wineusb-so.sh`)

AiM devices — notably the **USB-only PDM**, which has no WiFi/SD fallback — are vendor-class
**WinUSB** devices (`Class=USBDevice`, VID `0x11CC`; PID `0x0130` = "AiM Device 1.3"). On Windows RS3
opens them via `WinUsb_Initialize`. Wine implements that as `winusb.dll` (the API, **already** in the
Gcenx bundle) backed by **`wineusb.sys`** — the raw-USB *bus* driver whose unixlib (`wineusb.so`) is
**libusb-backed**. Wine's `configure` *disables `wineusb.sys` entirely* when libusb-1.0 isn't found,
and the Gcenx `osx64` bundle was built without it — so `wineusb.{sys,so}` + `wineusb.inf` are absent
and `winusb.dll` has nothing to bind. (Vendor-class is the *favorable* case on macOS: no Apple class
driver claims the interface, so libusb opens it directly — no kext, no SIP, unlike HID.)

`build-wineusb-so.sh` fixes the gap with **no source patch** — a pure rebuild with `--with-usb`:

| File | Role |
|------|------|
| `build-wineusb-so.sh` | cross-builds an **x86_64** libusb (brew's is arm64-only), configures the pinned Wine `--with-usb`, builds `wineusb.so` (unix) + `wineusb.sys` (PE) → `build/wineusb/`. Hard-asserts configure detected libusb and the module is x86_64 + links libusb. |

Outputs (`build/wineusb/`): `x86_64-unix/wineusb.so`, `x86_64-unix/libusb-1.0.0.dylib` (loaded via
`@loader_path`, so no Homebrew runtime dep), `{x86_64,i386}-windows/wineusb.sys`, `wineusb.inf`.
`build-apps.sh` **step 1f** adds them to the bundle (Mach-O, so before signing), **gated behind
`INCLUDE_USB=1`**. CI builds this and sets the flag **only for `-usb` prerelease tags** — stable
releases stay USB-free until the feature is validated on real AiM hardware.

### Prefix registration — fresh installs only (verified locally)

A **fresh** Wine prefix self-registers the `wineusb` bus during `wineboot --init` (because the bundle
now ships `wine.inf`'s referenced `wineusb.inf` + the driver) and immediately enumerates host USB
through libusb — **no launcher code needed**. Verified locally: a clean prefix lists the Mac's own USB
devices via the new driver.

**Existing prefixes do NOT get USB by upgrading in place.** Wine builds the live PnP device stack only
at first init; transplanting the registry keys / running `wineboot -u` on an already-created prefix is
not sufficient (tested — the service/Class binding doesn't take). So a **clean install** (uninstall,
then install) is required to enable USB today. Existing prefixes are inert-but-safe: the driver only
loads once registered, so nothing changes for Wi-Fi/SD users who upgrade.

Still **unverified on AiM hardware**: whether RS3 completes the WinUSB handshake with a plugged-in PDM
and pushes a config (`WinUsb_WritePipe`, write-heavy). That's what the `-usb` prerelease tests. See
memory `usb-pdm-winusb-path`.

```bash
bash installer/wine-patch/build-wineusb-so.sh             # -> build/wineusb/...
INCLUDE_USB=1 NO_DMG=1 bash installer/build/build-apps.sh  # adds it to the bundle (step 1f)
```
