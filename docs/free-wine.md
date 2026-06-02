# Running it free (no CrossOver)

[CrossOver](https://www.codeweavers.com/crossover) is the easy, paid path (~$74,
[14-day free trial](https://www.codeweavers.com/crossover/download) ·
[buy](https://www.codeweavers.com/store)). RaceStudio 3 can run on **free Wine** too — but
as of mid-2026, **no free option matches a current CrossOver's clean experience**, and the
reason is subtle.

## TL;DR (tested on Apple Silicon, RS3 3.83.20)
| Stack | Wine base | Graphics | RS3 result |
|-------|-----------|----------|------------|
| **CrossOver** (current, paid) | Wine 10+ | D3DMetal | ✅ runs, renders clean |
| **GPTk 3.0** (free) | **Wine 7.7** | D3DMetal | ⚠️ runs, **garbled text** (verified) |
| WineHQ `wine-stable` 11 (free) | Wine 11 | none | ❓ untested — install needs `sudo`, deprecated |
| any Wine ≤ 8 (old) | Wine 8 or older | — | ⚠️ garbled text (the bug this works around) |

**The lesson:** RaceStudio 3's text/UI rendering quality tracks the **Wine version**, not
the graphics layer. CEF's text rendering is broken on Wine ≤8 and fixed around Wine 10.
GPTk has Apple's excellent **D3DMetal** graphics but is stuck on a **Wine 7.7** base, so it
shows garbled text anyway — good D3D doesn't help. The only stack today that pairs a
**modern Wine** with **good graphics** is a current CrossOver. That's what you're paying for.

So: **for clean daily use, a current CrossOver is worth the money.** Free Wine (GPTk) is fine for
**offline `.xrk` analysis** if you can tolerate UI glitches. RaceStudio 3 renders its UI
with Chromium (CEF), so graphics translation matters — but the Wine *version* matters more
for the text bug specifically.

One nice side effect of *real* Wine (vs CrossOver's wrapper): it honors `WINEPREFIX` and
resolves paths normally, so **winetricks just works and you don't need the `cxwine` shim**
from the old-CrossOver notes.

## Free options, best-to-worst for this app (Apple Silicon)

1. **Gcenx `wine-crossover` / `winecx`** — CrossOver's own Wine, repackaged free, *with*
   D3DMetal. Best chance of matching CrossOver's rendering.
   ```sh
   brew tap gcenx/wine
   brew install --cask --no-quarantine wine-crossover   # check the current cask name
   # then: WINEPREFIX=~/rs3 wineboot -i ; WINEPREFIX=~/rs3 wine RaceStudio3-64_xxx.exe
   ```
2. **Apple Game Porting Toolkit (GPTk 2.x) Wine** — free from Apple, excellent Metal
   graphics. Heavier to set up (needs the GPTk environment).
3. **Kegworks** (maintained Wineskin fork) — free, GUI wrapper, app-bundle workflow.
   <https://github.com/Kegworks-App/Kegworks>
4. **Whisky** — free GUI, but development ended in early 2025 and it's flaky on recent
   macOS. Not recommended in 2026.
5. **Plain WineHQ** (`brew install --cask wine-stable`) — works, but the weakest graphics
   path → most likely to reintroduce the CEF rendering bugs. Usable for offline `.xrk`
   analysis if you can tolerate UI glitches.

## Method on free Wine (any of the above, prefix-based)
```sh
export WINEPREFIX="$HOME/rs3"            # a fresh prefix
wineboot -i                              # initialize
winetricks -q dotnet48                   # installer needs .NET (no shim needed here)
wine "RaceStudio3-64_xxx.exe"            # run installer; if Enhanced UI crashes, add /exenoui
```
If you're on an older Wine and hit the MSI file-copy hang, the extract-and-deploy trick
from [old-crossover-workarounds.md](old-crossover-workarounds.md) §4 applies verbatim
(the app extracts to `C:\AIM_SPORT\RaceStudio3\`).

## Honest recommendation
- Want it to *just work* with the least fuss: **current CrossOver**.
- Want free and willing to tinker: **Gcenx `wine-crossover`** (closest to CrossOver) or
  **GPTk Wine**.
- Avoid: plain WineHQ for the GUI (fine for headless `.xrk` only), and Whisky in 2026.

(Verified end-to-end on CrossOver; the free paths are documented but community-test them
and send a PR with what worked.)
