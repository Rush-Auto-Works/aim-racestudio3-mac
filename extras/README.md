# Optional extras

Things you *can* do but the installer never does for you (they change system-wide macOS behavior,
so they're opt-in).

## Stop the "Intel app support is ending" reminder

macOS 26.4 (Tahoe) shows a periodic warning whenever you launch an Intel/Rosetta app — and
RaceStudio 3 is an Intel app, so you'll see it. Two ways to turn it off (it affects **all** Rosetta
apps on your Mac, not just RaceStudio 3):

**1. Quick (per-user) — may or may not stick, since this is normally a managed setting:**
```sh
defaults write com.apple.applicationaccess allowRosettaUsageAwareness -bool false
```
Then fully quit and relaunch the app. If the warning still appears, use the profile below.

**2. Reliable — install the configuration profile:**
1. Double-click [`disable-intel-app-warning.mobileconfig`](disable-intel-app-warning.mobileconfig).
2. Open **System Settings → General → Device Management** (or **Privacy & Security → Profiles**),
   select the profile, and click **Install**.
3. Relaunch RaceStudio 3 — the reminder is gone.

To undo: remove the profile from the same screen, or
`defaults delete com.apple.applicationaccess allowRosettaUsageAwareness`.

> This only silences the reminder. Rosetta 2 itself still works; when Apple eventually removes
> Rosetta in a future macOS, Intel apps (including this one under the current Wine) will need a
> newer engine. That's a separate, later concern.
