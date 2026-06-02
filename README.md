# RaceStudio 3 on a Mac — no Windows, no Parallels

Run AiM's **RaceStudio 3** on your Mac in its own window: open your `.xrk` sessions, your
device configs and profiles, and connect to your AiM logger or dash over WiFi. No Windows
license, no giant virtual machine.

![RaceStudio 3 running on a Mac](img/working-config-shift-lights.png)
*RaceStudio 3 running on an Apple Silicon Mac — the real app, in a normal Mac window.*

---

## Two ways to install

| | **Option A — Free app** | **Option B — CrossOver** |
|---|---|---|
| Cost | **Free** | ~$74 (14-day free trial) |
| Effort | Drag to Applications, open once | Install CrossOver, then RaceStudio 3 |
| Looks correct? | **Yes** (uses a modern engine) | Yes (keep it updated) |
| Best for | Most people | Those who already own CrossOver |

Both run the *real* RaceStudio 3 in a normal Mac window, open your `.xrk` files, and connect
to AiM devices over WiFi. **Option A is the easy, free path** — start there.

---

## Option A — the free app (recommended)

No Windows, no Parallels, no CrossOver, nothing to buy. It's a normal Mac app; the first time you
open it, it sets itself up.

1. **Download `RaceStudio 3.dmg`** from this repo's
   [**Releases**](https://github.com/Rush-Auto-Works/aim-racestudio3-mac/releases) page and open it.
2. **Drag the `AiM` folder onto the Applications folder** (the disk image shows an arrow). That
   one drag installs everything to `/Applications/AiM`: **RaceStudio 3**, plus the **Import** and
   **Uninstall** helper apps.
3. **Open RaceStudio 3** from **Applications ▸ AiM**. The **first launch** sets everything up — it
   downloads the bits it needs and configures RaceStudio 3 for you (about 10 minutes, needs
   internet, no Terminal ever). Every launch after that just opens the app.

That's it. Your data lives in **`~/Documents/AIM_SPORT`**; the engine lives quietly in
`~/Library/Application Support/RaceStudio3`. The **Import RaceStudio 3 Data** and **Uninstall
RaceStudio 3** apps sit beside RaceStudio 3 in **`/Applications/AiM`** — for bringing data in and
cleanly removing everything later.

**A couple of normal prompts you might see on first launch:**
- *"Wine wants to access Documents"* — click **Allow**. (It says *Wine*, the open-source
  engine doing the work, not RaceStudio 3.) This is how it reaches your data folder.
- If your **Documents folder syncs to iCloud**, it offers to keep your telemetry in a safe
  local folder instead — iCloud's "Optimize Storage" can otherwise move your database off the
  Mac and break it. Pick the safe option if unsure.

**To uninstall:** open **Uninstall RaceStudio 3** in `/Applications/AiM` — it stops RaceStudio 3
and removes everything in `/Applications/AiM` (the app, the engine, and the helpers); your data in
`~/Documents/AIM_SPORT` is kept unless you choose to remove it. (Manual route, same result: delete
the `/Applications/AiM` folder and `~/Library/Application Support/RaceStudio3`.)

> **Don't see a release yet?** The notarized DMG is produced from this repo by
> `installer/build/build-apps.sh` (needs an Apple Developer ID). Until a release is posted you
> can build it yourself, or use **Option B** below. Full design notes:
> [docs/installer-design.md](docs/installer-design.md).

### Bringing data in is just as easy

**Drag your old `AIM_SPORT` folder** (from another PC, a USB stick, a backup, or a Parallels
shared folder) — or a `.zip` of it, or loose `.xrk` files — **straight onto the RaceStudio 3
app**. It merges everything in and **never overwrites** what you already have. (More options in
[Bring your sessions over](#bring-your-sessions-configs-and-profiles-over) below.)

---

## Option B — CrossOver (about 10 minutes, no Terminal)

- **A Mac** (any Apple Silicon M-series, or Intel).
- **CrossOver** — a small paid app that runs Windows programs on a Mac.
  [Home](https://www.codeweavers.com/crossover) ·
  [Free 14-day trial](https://www.codeweavers.com/crossover/download) ·
  [Buy (~$74)](https://www.codeweavers.com/store)
- **The RaceStudio 3 installer** — free from AiM:
  [download page](https://www.aim-sportline.com/en/sw-fw-download.htm).

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

That means the **engine underneath is too old**. RaceStudio 3's interface needs a modern
engine to draw correctly:
- **Option A (free installer):** it pins a known-good modern engine, so this shouldn't happen.
  If it does, run the **Uninstall** app and reinstall.
- **Option B (CrossOver):** **update CrossOver to the latest version and relaunch** — older
  versions are the usual cause. (If you genuinely can't update, manual workarounds are in
  [docs/old-crossover-workarounds.md](docs/old-crossover-workarounds.md).)

---

## For the curious / technical

Everything below is optional background and command-line detail — you don't need it for a
normal install.

### Why a "modern engine" matters
RaceStudio 3's interface is built on Chromium (the engine behind Chrome), which only draws
correctly on a **modern version of Wine** (the open-source Windows-compatibility layer; both
CrossOver and the free installer are built on it). The garbled-text reports all trace back to
*old* Wine (Wine 8 and earlier); **Wine 10+ renders it cleanly**. That's why the free
installer (Option A) pins a verified recent Wine, and why a current CrossOver (Option B) works
while old ones don't. Full tested comparison: [docs/free-wine.md](docs/free-wine.md).

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

### How the free installer (Option A) works
It's a notarized AppleScript app whose brain is a well-tested bash engine
(`installer/src/`). It installs a pinned, verified Wine into
`~/Library/Application Support/RaceStudio3/`, runs AiM's installer silently, then relocates
your `user/` data out to `~/Documents/AIM_SPORT` and symlinks it back — crash-atomically, so
an interrupted install never loses data. Build it with `installer/build/build-apps.sh`; the
engine has a full test suite (`bash installer/test/run-all.sh`, plus an offline real-install
`installer/test/e2e-local.sh`).

### More docs
- [docs/installer-design.md](docs/installer-design.md) — the free installer's design (reviewed).
- [docs/installer-implementation.md](docs/installer-implementation.md) — build plan + the
  data-safety state machine.
- [docs/free-wine.md](docs/free-wine.md) — running it free (no CrossOver), with tested results.
- [docs/old-crossover-workarounds.md](docs/old-crossover-workarounds.md) — manual fixes for
  old/free Wine (only if you can't use a current CrossOver).

---

*Community guide, worked out on a 2026 Apple Silicon Mac with RaceStudio 3 v3.83.20. Not
affiliated with AiM or CodeWeavers. Corrections and PRs welcome.*
