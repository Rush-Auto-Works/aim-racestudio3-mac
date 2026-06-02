# RaceStudio 3 on a Mac — no Windows, no Parallels

Run AiM's **RaceStudio 3** on your Mac in its own window: open your `.xrk` sessions, your
device configs and profiles, and connect to your AiM logger or dash over WiFi. No Windows
license, no giant virtual machine.

![RaceStudio 3 running on a Mac](img/working-config-shift-lights.png)
*RaceStudio 3 running on an Apple Silicon Mac — the real app, in a normal Mac window.*

> **Independent community project — not affiliated with AiM.** This is built by enthusiasts. It is
> **not owned, sanctioned, endorsed, or supported by AiM Tech / AiM Sportline**, and has no official
> relationship with AiM on the software side. "RaceStudio 3" and "AiM" are trademarks of their
> respective owners, used here only to describe what this project helps you run. Use at your own risk.

---

## Install (free, about 10 minutes)

No Windows, no Parallels, nothing to buy. It's a normal Mac app; the first time you open it, it
sets itself up.

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
  local folder (`~/AIM_SPORT`) instead of `~/Documents/AIM_SPORT` — iCloud's "Optimize Storage"
  can otherwise move your database off the Mac and break it. Pick the safe option if unsure (so
  on an iCloud-synced Mac your data lives in `~/AIM_SPORT`, which is expected).

**To uninstall:** open **Uninstall RaceStudio 3** in `/Applications/AiM` — it stops RaceStudio 3,
removes the apps in `/Applications/AiM`, and removes the engine in
`~/Library/Application Support/RaceStudio3`; your data in `~/Documents/AIM_SPORT` is kept unless you
choose to remove it. (Manual route, same result: delete the `/Applications/AiM` folder and the
`~/Library/Application Support/RaceStudio3` engine folder.)

> **Don't see a release yet?** The notarized DMG is produced from this repo by
> `installer/build/build-apps.sh` (needs an Apple Developer ID). Until a release is posted you
> can build it yourself. Full design notes: [docs/installer-design.md](docs/installer-design.md).

### Bringing data in is just as easy

**Drag your old `AIM_SPORT` folder** (from another PC, a USB stick, a backup, or a Parallels
shared folder) — or a `.zip` of it, or loose `.xrk` files — **straight onto the RaceStudio 3
app**. It merges everything in and **never overwrites** what you already have. (More options in
[Bring your sessions over](#bring-your-sessions-configs-and-profiles-over) below.)

---

## Bring your sessions, configs, and profiles over

Two ways, easiest first:

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

---

## Connecting your AiM device

- **Over WiFi: works great.** Join your device's WiFi network from macOS System Settings
  (Wi-Fi), then connect inside RaceStudio 3 just like on Windows.
- **By USB cable: not supported.** The cable connection doesn't work through Wine. Use
  WiFi, or pull data off the device's SD card / export.

---

## If the text looks garbled or broken

That means the **engine underneath is too old**. RaceStudio 3's interface needs a modern engine
to draw correctly. The installer pins a known-good modern engine, so this shouldn't happen — if
it does, run the **Uninstall** app and reinstall.

---

## For the curious / technical

Everything below is optional background and command-line detail — you don't need it for a
normal install.

### Why a "modern engine" matters
RaceStudio 3's interface is built on Chromium (the engine behind Chrome), which only draws
correctly on a **modern version of Wine** (the open-source Windows-compatibility layer). The
garbled-text reports all trace back to *old* Wine (Wine 8 and earlier); **Wine 10+ renders it
cleanly**. That's why the installer pins a verified recent Wine. Full tested comparison:
[docs/free-wine.md](docs/free-wine.md).

### Where RaceStudio 3 keeps your data
Your telemetry lives in `~/Documents/AIM_SPORT`, kept outside the app so updates and uninstalls
never touch it. The Wine engine and Windows environment live quietly in
`~/Library/Application Support/RaceStudio3`.

| Data | Location |
|------|----------|
| Configs, profiles, track **database**, settings | `~/Documents/AIM_SPORT/` |
| Logged sessions (`.xrk`) | `~/Documents/AIM_SPORT/data/` |

(Inside the Windows environment RaceStudio 3 installs to `C:\AIM_SPORT\RaceStudio3\`; the app
itself is `64\AiMRS3-64-ReleaseU.exe`.)

### How the installer works
It's a notarized AppleScript app whose brain is a well-tested bash engine
(`installer/src/`). It installs a pinned, verified Wine into
`~/Library/Application Support/RaceStudio3/`, runs AiM's installer silently, then relocates
your `user/` data out to `~/Documents/AIM_SPORT` and symlinks it back — crash-atomically, so
an interrupted install never loses data. Build it with `installer/build/build-apps.sh`; the
engine has a full test suite (`bash installer/test/run-all.sh`, plus an offline real-install
`installer/test/e2e-local.sh`).

### More docs
- [docs/installer-design.md](docs/installer-design.md) — the installer's design (reviewed).
- [docs/installer-implementation.md](docs/installer-implementation.md) — build plan + the
  data-safety state machine.
- [docs/free-wine.md](docs/free-wine.md) — the modern-Wine comparison, with tested results.

---

*Independent community project — not affiliated with, owned by, or sanctioned by AiM. Worked out on
a 2026 Apple Silicon Mac with RaceStudio 3 v3.83.20. Corrections and PRs welcome.*
