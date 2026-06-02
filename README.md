# RaceStudio 3 on a Mac — no Windows, no Parallels

Run AiM's **RaceStudio 3** on your Mac in its own window: open your `.xrk` sessions, your
device configs and profiles, and connect to your AiM logger or dash over WiFi. No Windows
license, no giant virtual machine.

![RaceStudio 3 running on a Mac](img/working-config-shift-lights.png)
*RaceStudio 3 running on an Apple Silicon Mac — the real app, in a normal Mac window.*

---

## What you'll need

- **A Mac** (any Apple Silicon M-series, or Intel).
- **CrossOver** — a small app that runs Windows programs on a Mac.
  [Home](https://www.codeweavers.com/crossover) ·
  [Free 14-day trial](https://www.codeweavers.com/crossover/download) ·
  [Buy (~$74)](https://www.codeweavers.com/store)
- **The RaceStudio 3 installer** — free from AiM:
  [download page](https://www.aim-sportline.com/en/sw-fw-download.htm).

> There are *free* alternatives to CrossOver, but right now they show garbled text and
> display glitches in RaceStudio 3. CrossOver is the one that looks correct. If you want to
> try the free route anyway, see [docs/free-wine.md](docs/free-wine.md).

---

## Install it (about 10 minutes, no Terminal needed)

1. **Install CrossOver.** If you already have it, **make sure it's updated to the latest
   version** — this matters; older versions make RaceStudio 3 misbehave.
2. **Download the RaceStudio 3 installer** from AiM (link above). It lands in your
   Downloads folder.
3. **Open CrossOver**, click **Install**, and pick the RaceStudio 3 installer you just
   downloaded. When it offers to, let it create a **new Windows 10 space** (CrossOver calls
   these "bottles") — name it `RaceStudio3`.
4. **Click through the RaceStudio 3 setup** exactly like on Windows: **Next → Install →
   Finish**.
5. **Launch RaceStudio 3** from CrossOver. That's it — it opens in its own window.

CrossOver puts a normal app icon in your Applications for next time. Done.

---

## Bring your sessions, configs, and profiles over

Three ways, easiest first:

### 1. Let an AI assistant do it
Open **[LLM-PROMPT.md](LLM-PROMPT.md)**, copy the whole thing, and paste it into an AI
assistant on your Mac (Claude, ChatGPT, etc.). It will find your old data — wherever it is,
including inside a Parallels Windows setup — and copy it into RaceStudio 3 for you.

### 2. Use RaceStudio 3's built-in Import
Inside RaceStudio 3 use its **Import / Export** buttons (same as on Windows). Good for a
handful of sessions or configs.

> **Finding your Mac files in RaceStudio 3's Open/Import window:** RaceStudio 3 thinks it's
> on Windows, so your Mac folders aren't under "Documents." In the file window, go to
> **This PC → `Z:` → Users → your-name**. That's your real Mac home — so your Desktop,
> Documents, and Downloads are right there under `Z:\Users\your-name\`.

### 3. Copy everything at once (needs Terminal)
If you're comfortable in Terminal and your old data is in a Parallels Windows VM, the
script **`scripts/port-data-from-parallels.sh`** copies your *entire* history — every
config, profile, the full track database, and your sessions — in one shot. Details in
[For the curious / technical](#for-the-curious--technical) below.

---

## Connecting your AiM device

- **Over WiFi: works great.** Join your device's WiFi network from macOS System Settings
  (Wi-Fi), then connect inside RaceStudio 3 just like on Windows.
- **By USB cable: not supported.** The cable connection doesn't work through CrossOver. Use
  WiFi, or pull data off the device's SD card / export.

---

## If the text looks garbled or broken

That almost always means **CrossOver is out of date** (or you're using a free Wine build).
**Update CrossOver to the latest version and relaunch** — that fixes the garbled text and
broken panels. (If you genuinely can't update, there are manual workarounds in
[docs/old-crossover-workarounds.md](docs/old-crossover-workarounds.md).)

---

## For the curious / technical

Everything below is optional background and command-line detail — you don't need it for a
normal install.

### Why CrossOver, and why "update it" matters
RaceStudio 3's interface is built on Chromium (the engine behind Chrome), which only draws
correctly on a **modern version of Wine** (the Windows-compatibility technology CrossOver is
built on). A current CrossOver includes that; old ones don't, which is where the garbled
text comes from. The free alternatives we tested are stuck on an old Wine and show the same
glitches — full tested comparison in [docs/free-wine.md](docs/free-wine.md).

### Where RaceStudio 3 keeps your data (inside the bottle)
The "bottle" is just a normal folder on your Mac:
`~/Library/Application Support/CrossOver/Bottles/RaceStudio3/drive_c/`

| Data | Inside the bottle |
|------|-------------------|
| Configs, profiles, track **database**, settings | `…/drive_c/AIM_SPORT/RaceStudio3/user/` |
| Logged sessions (`.xrk`) | `…/drive_c/AIM_SPORT/RaceStudio3/user/data/` |

(RaceStudio 3 installs to `C:\AIM_SPORT\RaceStudio3\`; the app itself is
`64\AiMRS3-64-ReleaseU.exe`.)

### Command-line helpers (`scripts/`)
- `install-crossover.sh` — create the bottle and run the installer from Terminal.
- `make-launcher.sh` — drop a double-clickable launcher in `~/Applications`.
- `port-data-from-parallels.sh` — bulk-copy your data out of a **running** Parallels VM:
  ```bash
  ./scripts/port-data-from-parallels.sh --vm "Win11" --bottle "RaceStudio3" --since 2025-01-01
  ```
  It copies the whole `user/` folder (configs + profiles + database) plus every session
  newer than `--since`. First launch afterward is slow for a minute while RaceStudio 3
  rebuilds config thumbnails — normal, one-time.

### More docs
- [docs/free-wine.md](docs/free-wine.md) — running it free (no CrossOver), with tested results.
- [docs/old-crossover-workarounds.md](docs/old-crossover-workarounds.md) — manual fixes for
  old/free Wine (only if you can't use a current CrossOver).

---

*Community guide, worked out on a 2026 Apple Silicon Mac with RaceStudio 3 v3.83.20. Not
affiliated with AiM or CodeWeavers. Corrections and PRs welcome.*
