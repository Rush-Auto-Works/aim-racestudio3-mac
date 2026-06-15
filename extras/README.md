# Optional extras

Things you *can* do but the installer never does for you (they change system-wide macOS behavior,
so they're opt-in).

## Stop the "Intel app support is ending" reminder

macOS 26.4 (Tahoe) shows a periodic warning whenever you launch an Intel/Rosetta app — and
RaceStudio 3 is an Intel app, so you'll see it. The fix is to install the configuration profile
below (it affects **all** Rosetta apps on your Mac, not just RaceStudio 3). No MDM or supervision
is required — a profile you install yourself is enough.

**Install the configuration profile:**
1. Double-click [`disable-intel-app-warning.mobileconfig`](disable-intel-app-warning.mobileconfig).
   macOS queues it (no immediate dialog on 26.x).
2. Open **System Settings → General → Device Management** (or **Privacy & Security → Profiles**),
   select the profile, and click **Install**.
3. Fully quit and relaunch RaceStudio 3 — the reminder is gone.

To confirm it took effect:
`ls /Library/Managed\ Preferences/$USER/com.apple.applicationaccess.plist` should now exist.

To undo: remove the profile from the same screen.

> **Don't bother with `defaults write com.apple.applicationaccess allowRosettaUsageAwareness …`.**
> It's a dead end. `allowRosettaUsageAwareness` is a *managed restriction*: macOS reads it only from
> the managed-preferences layer (`/Library/Managed Preferences/`), which a configuration profile
> writes to. A plain `defaults write` lands in your local user domain, where the OS never looks for
> it, so the warning keeps appearing even though `defaults read` shows the value you set.
>
> **The CLI can no longer install profiles** on macOS 26.5+ (`profiles install` reports
> "profiles tool no longer supports installs. Use System Settings Profiles…"). The double-click +
> System Settings approval above is the only route.

> This only silences the reminder. Rosetta 2 itself still works; when Apple eventually removes
> Rosetta in a future macOS, Intel apps (including this one under the current Wine) will need a
> newer engine. That's a separate, later concern.
