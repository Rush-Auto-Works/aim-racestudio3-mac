# RaceStudio 3 on a Mac (Apple Silicon) — no Parallels, no Windows

Run AiM's **RaceStudio 3** telemetry software natively-ish on an Apple Silicon Mac
(M1/M2/M3/M4/M5) using **CrossOver**, and bulk-import your existing sessions, configs,
and profiles from a Windows/Parallels install.

No Windows license, no 60 GB virtual machine. Just RaceStudio 3 in a window.

![RaceStudio 3 running on macOS via CrossOver](img/working-config-shift-lights.png)
*RaceStudio 3 (v3.83.20) running on an Apple Silicon Mac under a current CrossOver — clean text, full UI.*

> **TL;DR:** On a **current CrossOver (v24+, ideally v26+)** the official AiM installer
> *just works*. Make a Windows 10 bottle, run the installer, click through. Done.
> Everything below the "Easy path" is optional (data import) or only needed on old Wine.

---

## What you get

- RaceStudio 3 (the full Windows app) running in its own window on macOS
- Opening/analyzing your `.xrk` data, your device configs, your profiles
- Connecting to AiM devices **over WiFi** (network works; USB cable passthrough does not)
- ~1 GB on disk instead of a ~60 GB Windows VM

## What you need

| Thing | Notes |
|-------|-------|
| Apple Silicon Mac | Tested on M5 Max, macOS 26. Intel Macs work too (no Rosetta needed). |
| **CrossOver** — [home](https://www.codeweavers.com/crossover) · [download / free trial](https://www.codeweavers.com/crossover/download) · [buy](https://www.codeweavers.com/store) | Paid (~$74), 14-day free trial. Use a **current** version. This is the easy path. Free Wine alternatives in [docs/free-wine.md](docs/free-wine.md). |
| RaceStudio 3 installer | Free from AiM: <https://www.aim-sportline.com/en/sw-fw-download.htm> |

### Why CrossOver and not free Wine?
RaceStudio 3 is a **Chromium (CEF) + native** app, and its text/UI renders cleanly only on
a **modern Wine** (≈ Wine 10+). A current CrossOver ships exactly that, paired with good
graphics. The free options we tested either use an **old Wine base** (Apple's Game Porting
Toolkit is Wine 7.7 → garbled text, even with great graphics) or are awkward to install —
so free Wine is fine for **offline `.xrk` analysis** but glitchy for daily UI use. Full
tested comparison and the no-CrossOver routes are in [docs/free-wine.md](docs/free-wine.md).

---

## Easy path (current CrossOver) — 5 steps

1. **Install CrossOver** ([download / free trial](https://www.codeweavers.com/crossover/download)).
   If you already have it, **make sure it's up to date** — a current version is what makes
   the installer and UI rendering "just work"; older Wine builds don't.
2. **Download** the RaceStudio 3 installer (`RaceStudio3-64_*.exe`) from AiM (link above).
3. **Make a bottle:** open CrossOver → **+ Install** → choose **"unlisted application"** →
   select the installer → when asked, create a **new Windows 10 bottle** (name it
   `RaceStudio3`).
4. **Run the installer**, click **Next → Install → Finish** like on Windows.
5. **Launch RaceStudio 3** from CrossOver. That's it.

> Prefer the command line? `scripts/install-crossover.sh` does steps 3–4 headlessly.

RaceStudio 3 installs to `C:\AIM_SPORT\RaceStudio3\` inside the bottle and the main
executable is `64\AiMRS3-64-ReleaseU.exe`.

### Make it double-clickable
CrossOver auto-creates an app launcher in `~/Applications/CrossOver/…`. You can also
drop a tiny launcher on your Desktop — see `scripts/make-launcher.sh`.

---

## Bringing your data over (sessions, configs, profiles) — in bulk

You can always use RaceStudio 3's built-in **Import/Export**, but to move *everything*
at once it's faster to copy the files directly into the bottle.

### Where RaceStudio 3 keeps things

| Data | Windows location | Bottle location (inside CrossOver) |
|------|------------------|-------------------------------------|
| Configs (`.zconfig`), profiles, **database**, tracks, settings | `C:\AIM_SPORT\RaceStudio3\user\` | `…/Bottles/RaceStudio3/drive_c/AIM_SPORT/RaceStudio3/user/` |
| Logged sessions (`.xrk`) | wherever your "data" folder points (often `…\user\data` or a separate drive like `E:\data`) | `…/AIM_SPORT/RaceStudio3/user/data/` |

The bottle's `drive_c` is a normal Mac folder:
`~/Library/Application Support/CrossOver/Bottles/RaceStudio3/drive_c/`

### Option A — copy from a Parallels (or other) Windows VM, automatically

`scripts/port-data-from-parallels.sh` does the whole thing: it talks to your **running**
Parallels VM, finds the RaceStudio 3 `user\` folder and your recent `.xrk` sessions,
copies them out through a Parallels shared folder, and drops them into the bottle.

```bash
# close RaceStudio 3 in the bottle first, then:
./scripts/port-data-from-parallels.sh --vm "Win11" --bottle "RaceStudio3" --since 2025-01-01
```

It copies the **entire `user/` tree** (configs + profiles + the big track database) and
every session newer than `--since`. First launch after this will be slow for a minute
while RaceStudio 3 regenerates config preview thumbnails — that's a one-time cost.

> **Tip:** the `data.lnk` shortcut Windows uses to redirect the data folder to another
> drive won't resolve in the bottle — the script replaces it with a real `data/` folder
> so RaceStudio 3 finds your sessions.

### Option B — you already have the files on your Mac

If your `.xrk` files / configs are already on the Mac (Dropbox, a copied folder, etc.),
just copy them into the bottle locations in the table above, or use RaceStudio 3's
**Import** inside the app.

### Novice tip: finding your Mac files in RaceStudio 3's file picker
Inside RaceStudio 3 (a "Windows" app), your Mac folders aren't under "Documents" where
you'd expect. In any **Open/Import** dialog, navigate to:

```
This PC  →  Z:  →  Users  →  <your-mac-username>
```

`Z:` is mapped to your whole Mac (`/`), so
`Z:\Users\<your-name>\Desktop`, `…\Documents`, `…\Downloads` are your real Mac folders.
(If `Z:` isn't there, type `\\Mac\Home\` or `Z:\Users\<your-name>\` into the path bar.)

---

## Connecting to your AiM device

- **WiFi: works.** Join the device's WiFi network in macOS System Settings, then connect
  in RaceStudio 3 over the network like normal. Wine passes TCP/IP straight to the Mac.
- **USB cable: does not work** reliably (Wine can't pass AiM's USB device through). Use
  WiFi, or pull data via SD/export.

---

## Troubleshooting / old or free Wine

On an **old Wine (8 or older)** — an out-of-date CrossOver, or a free build like Apple's
Game Porting Toolkit — the official installer crashes and the UI renders with garbled
text. There's a full set of workarounds (install .NET 4.8, a `cxwine` shim for CrossOver's
wrapper, Win7-mode to skip a hanging theme action, extracting the app tree manually
because the MSI's file-copy hangs) documented in
**[docs/old-crossover-workarounds.md](docs/old-crossover-workarounds.md)** — useful if you
*must* use an older or free Wine.

**The real fix is a modern Wine.** Every one of those hacks disappears on Wine 10+ — i.e.
a current CrossOver.

---

## Want an AI to do this for you?

Paste **[LLM-PROMPT.md](LLM-PROMPT.md)** into Claude Code / ChatGPT / any capable coding
assistant on your Mac and it will walk through the install and data import for your
specific setup.

---

## Credits / status

Worked out on a 2026 Apple Silicon Mac with a current CrossOver, RaceStudio 3 v3.83.20.
Community contribution, not affiliated with AiM or CodeWeavers. PRs welcome.
