# Running it free (no CrossOver)

[CrossOver](https://www.codeweavers.com/crossover) is the *easy* paid path (~$74,
[14-day free trial](https://www.codeweavers.com/crossover/download) ·
[buy](https://www.codeweavers.com/store)). But there **is** a genuinely free path that
renders RaceStudio 3 just as cleanly — it's only a bit more hands-on to set up.

## TL;DR (tested on Apple Silicon, RS3 3.83.20)
| Stack | Wine base | Graphics | RS3 result |
|-------|-----------|----------|------------|
| **CrossOver** (current, paid) | Wine 10+ | D3DMetal | ✅ clean — easiest install (GUI) |
| **Gcenx Wine 11.9** (free, standalone) | **Wine 11** | none | ✅ **clean — verified**, more manual setup |
| GPTk 3.0 (free) | Wine 7.7 | D3DMetal | ⚠️ runs but **garbled text** (verified) |
| any Wine ≤ 8 (old/old CrossOver) | Wine 8 or older | — | ⚠️ garbled text |

**The lesson, now proven both ways:** RaceStudio 3's text/UI rendering tracks the **Wine
version**, not the graphics layer. CEF's text rendering is broken on Wine ≤8 and fixed by
**Wine 10 — any Wine ≥10 is fine** (10.x, 11, …). Apple's **GPTk** has excellent D3DMetal
graphics but a Wine **7.7** base → garbled. Plain **Wine 11** has *no* fancy graphics layer
but renders **perfectly**. So you do **not** need D3DMetal for RaceStudio 3 — just a modern
Wine.

So:
- **Easiest, costs money:** a current CrossOver (GUI bottle manager, installer just works).
- **Free and clean, a bit more setup:** Gcenx **Wine 11** (below). Recommended free route.
- **Avoid:** GPTk and any old Wine for the UI — they reintroduce the garbled text.

A nice bonus of *real* Wine (vs CrossOver's wrapper): it honors `WINEPREFIX` and resolves
paths normally, so **winetricks just works and you don't need the `cxwine` shim** from the
old-Wine notes.

---

## Free clean path: Gcenx standalone Wine 11 (no Homebrew, no sudo)

Gcenx publishes standalone macOS Wine builds as plain `.tar.xz` archives — no installer, no
`sudo`, no Homebrew. (Homebrew's `wine-stable` works too but drags in a `sudo` GStreamer
dependency, so the direct download is simpler.)

1. **Download a recent build** from
   <https://github.com/Gcenx/macOS_Wine_builds/releases> — e.g. `wine-staging-11.9-osx64.tar.xz`
   (or `wine-devel-…`). **Any Wine 10 or newer renders RaceStudio 3 cleanly** — the exact
   version doesn't matter, just grab a current one (we verified 11.9; 10.x is fine too).
   These are Intel builds; they run on Apple Silicon via Rosetta 2.
   ```sh
   cd ~/Downloads
   curl -fL -O https://github.com/Gcenx/macOS_Wine_builds/releases/download/11.9/wine-staging-11.9-osx64.tar.xz
   mkdir -p ~/wine11 && tar -xf wine-staging-11.9-osx64.tar.xz -C ~/wine11
   WINE="$HOME/wine11/Wine Staging.app/Contents/Resources/wine/bin/wine"
   ```
   (GStreamer is optional — only needed for in-app video; RaceStudio 3's analysis works
   without it.)

2. **Create a prefix and install RaceStudio 3.**
   ```sh
   export WINEPREFIX="$HOME/.racestudio3"
   "$WINE" wineboot --init
   "$WINE" "$HOME/Downloads/RaceStudio3-64_xxx.exe"      # run the AiM installer, click through
   ```
   On modern Wine the installer behaves like it does on CrossOver. If it gives you trouble,
   the app is xcopy-deployable — see the extract-and-deploy trick in
   [old-crossover-workarounds.md](old-crossover-workarounds.md) §4 (the app lands in
   `C:\AIM_SPORT\RaceStudio3\`).

3. **Run it.**
   ```sh
   "$WINE" "$WINEPREFIX/drive_c/AIM_SPORT/RaceStudio3/64/AiMRS3-64-ReleaseU.exe"
   ```
   Renders clean. *(Verified: a deployed RS3 3.83.20 runs with correct text on Wine 11.9
   Staging.)*

> Want a double-click launcher? Put that last command in a `.command` file in
> `~/Applications` (see `scripts/make-launcher.sh`, adjusting `WINE`/`WINEPREFIX`).

---

## Other free options (for completeness)
- **Apple Game Porting Toolkit** — free, superb D3DMetal graphics, but Wine **7.7** → shows
  the garbled text. Fine only for offline `.xrk` analysis you can squint through.
- **Kegworks** (maintained Wineskin fork) — free GUI wrapper; pick a **Wine 10+** engine and
  it should render clean. <https://github.com/Kegworks-App/Kegworks>
- **Whisky** — discontinued (early 2025), flaky on recent macOS. Skip in 2026.
- **Homebrew `wine-stable` 11** — modern Wine, but its install needs `sudo` (GStreamer) and
  is deprecated in Homebrew. The Gcenx tarball above is the same Wine without the hassle.

(Verified: CrossOver end-to-end; Gcenx Wine 11.9 renders a deployed RS3 cleanly. Community
PRs welcome for the installer-on-each-build and Kegworks specifics.)
