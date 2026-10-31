# Native arm64 Wine - investigated, not available anywhere yet

Contributed by [@sergeydgr8](https://github.com/sergeydgr8) in issue #27. The ecosystem survey below is as of 2026-07-09; re-check it before acting on it.

Status: **investigated, ruled out for now (2026-07-09).** Nothing to implement - this is a
"wait and watch" doc, not a spec. Revisit only if CrossOver's arm64 Mac build (in Preview as
of this writing) reaches GA with terms that permit redistributing its Wine fork in a free
open-source DMG, or if some other project ships a genuine native-arm64 Wine with x86_64
Windows-guest support.

## Problem

macOS shows "Support Ending for Intel-based Apps" for `RaceStudio 3.app`. The entire bundled
Wine runtime - `wine`/`wineserver`/unix libs (prebuilt, `pins.env` `WINE_PINNED_URL`) plus our
from-source unix modules `winemac.so` (`installer/wine-patch/build-winemac-so.sh`) and
`wineusb.so` (`installer/wine-patch/build-wineusb-so.sh`) - is x86_64 Mach-O, whole-process-
translated by Rosetta 2 (`arch -x86_64` in `installer/src/lib/wine.sh`, `installer-core.sh`, and
those two build scripts). Our patched `ws2_32.dll`/`wlanapi.dll`
(`installer/bridge/wine-patch/build-wine-dlls.sh`) are Windows PE DLLs cross-built with mingw, no
Rosetta involved. RS3 itself is a Windows **x86_64 PE** binary
(`AiMRS3-64-ReleaseU.exe`), so even a native-arm64 Wine host would still need *some* x86_64
CPU-translation path for the guest code - the host-process architecture and the guest-code
translation are two separate problems, and today nothing solves either half without Rosetta.

## What was checked (2026-07-09)

- **Vanilla WineHQ** (`gitlab.winehq.org/wine/wine`, `configure.ac`) - `HOST_ARCH=aarch64` is
  recognized generically (`configure.ac:163-170`), which is how Wine already runs natively on
  Linux ARM64 hosts. But that only makes Wine's *unix host process* arm64; it adds no CPU
  emulator for running x86/x86_64 **Windows guest** binaries on that host. On Linux ARM64,
  vanilla Wine only runs *ARM* Windows PE binaries natively - x86 guest support there comes
  from bolt-on projects (Hangover/QEMU, Box64/FEX), not upstream Wine. No `rosetta` references
  anywhere in Wine's macOS loader/build code.
- **Gcenx macOS builds** (`macOS_Wine_builds`, what `pins.env` pins) - configured with
  `--build=x86_64-apple-darwin` explicitly (confirmed in their README's Configure Options
  block). No arm64 variant published across the last ~10 releases (11.0–11.10, stable/devel/
  staging) checked via the GitHub releases API.
- **Apple's Game Porting Toolkit (GPTK)** - a repackaged CrossOver Wine fork + D3DMetal. Its
  own setup docs require `arch -x86_64 brew install game-porting-toolkit`, i.e. the whole
  process still runs under Rosetta 2 process-level translation, same as our build. (Also
  already ruled out for this project on licensing grounds - D3DMetal forbids redistribution in
  a free open-source DMG, per `docs/plans/2026-06-13-sharp-video-vout.md`.)
- **Whisky** (`Whisky-App/Whisky`, archived Apr 2025) and its active forks (`frankea/Whisky`,
  `moonshine`, `Bourbon`) - built on CrossOver 22.1.1 + GPTK. Same x86_64-under-Rosetta base.
  The archived repo's own current advice is "buy CrossOver instead."
- **Sikarugir** ("Wineskin successor," markets itself as running apps "natively") - its own
  docs describe exporting x86 execution flags so "the system kernel loads x86 instructions via
  the Rosetta translation framework" on Apple Silicon. Same architecture, different marketing.
- **CrossOver 27** (CodeWeavers, commercial) - per their blog "What's in and what's out for
  CrossOver 27" (2026-06-11), this is the *only* project actively building a genuinely
  native-arm64 Wine (no Rosetta at the host-process level at all). Linux ARM64 has been
  Preview-only since 2025-11; Mac ARM64 "should be available in a Preview release soon" as of
  the same post - **not GA**. Even the vendor most invested in solving this hasn't shipped it.

## Why "just build Wine for arm64 ourselves" doesn't work today

The project already has the toolchain to build individual Wine modules from source
(`build-winemac-so.sh` and `build-wineusb-so.sh` build unix modules under `arch -x86_64`;
`build-wine-dlls.sh` cross-builds PE DLLs with mingw). That does NOT transfer to building the whole unix host side as
arm64, because the missing piece isn't compiler support - `HOST_ARCH=aarch64` already works -
it's the x86_64-guest-code-translation layer that has to live *inside* an arm64 host process.
The only implementation of that on macOS is CodeWeavers' unreleased CrossOver-27 work; nothing
public or upstream provides it. Building it ourselves would mean reimplementing an unreleased
CodeWeavers R&D effort from scratch - a research project, not an engineering task with a known
recipe.

## The one non-Wine alternative: a real Windows-on-ARM VM

Parallels Desktop (Microsoft-authorized on Apple Silicon) or free/manual UTM can run genuine
Windows 11 ARM. Windows 11 ARM has its own built-in x86_64 emulator ("Prism"), so RS3 would run
translated *inside the guest OS* - the host-side VM app is itself arm64-native, so macOS's
Intel-app check never fires on it. This fully sidesteps the warning, but:

- needs a Windows 11 license (Parallels bundles/sells one; UTM does not provide one),
- adds VM overhead vs. a Wine process,
- abandons this project's entire premise - a free, one-click, no-Windows-license installer
  (see `README.md`, "no Windows, no Parallels", and `codemaps/architecture.md`: "no
  Windows/Parallels/CrossOver").

Not pursued for those reasons, but recorded here as the one alternative that *does* technically
solve the problem today.

## Recommendation

Nothing actionable right now. Ship as-is; the Rosetta 2 dependency stands until one of:

1. CrossOver's Mac arm64 Preview reaches GA **and** its Wine fork's licensing permits
   redistribution in a free open-source DMG (check terms again when this happens - GPTK's
   D3DMetal precedent suggests CodeWeavers' forks aren't always freely redistributable), or
2. some other project ships a genuine native-arm64 Wine with x86_64 Windows-guest support.

Apple has signaled Rosetta 2 may shrink in scope around macOS 28 (~2027) but hasn't set a hard
removal date; re-check this doc's ecosystem survey if/when that materializes, since the
landscape here is moving (CrossOver 27's Preview work is the thing to watch).

## References

- Current x86_64 build pipeline: `installer/src/pins.env` (`WINE_PINNED_URL`),
  `installer/build/build-apps.sh`, `installer/wine-patch/build-winemac-so.sh`,
  `installer/wine-patch/build-wineusb-so.sh`, `installer/bridge/wine-patch/build-wine-dlls.sh`,
  `installer/src/lib/wine.sh` (`arch -x86_64` wrapper).
- CodeWeavers blog, "What's in and what's out for CrossOver 27" (2026-06-11) - arm64 Mac
  Preview status.
- Gcenx `macOS_Wine_builds` README - `--build=x86_64-apple-darwin` Configure Options block.
- WineHQ `configure.ac` (`gitlab.winehq.org/wine/wine`) - `HOST_ARCH` handling, lines 163-170.
- Related prior ruling: `docs/plans/2026-06-13-sharp-video-vout.md` (D3DMetal/GPTK
  redistribution licensing).
- Researched live via web search 2026-07-09; no local repo state changed by this doc.
