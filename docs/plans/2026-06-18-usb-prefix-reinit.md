# USB prefix re-init — enabling WinUSB on existing installs without a manual reinstall

Status: SPEC (2026-06-18, revised after multi-model review). Depends on the USB build landing (PR #24)
and the on-hardware PDM handshake passing. Do not implement until USB is hardware-confirmed — there's
no point auto-migrating prefixes to a capability we haven't proven works.

## Problem

The `wineusb` bus driver (the libusb-backed raw-USB bus that `winusb.dll` binds to) is only planted
into a Wine prefix during a `wineboot --init` that runs with `wineusb.inf` + the driver present. Every
prefix already on a user's Mac was created by the libusb-less Gcenx Wine, so it has **no** `wineusb`
service and **no** `root\WINEUSB\0` device node. Dropping the new modules into the bundle does nothing
for those prefixes — the device stack is assembled once, at init, and the running PnP manager won't
replant a root bus from userspace after the fact (verified: `wineboot -u` and registry transplant are
both insufficient — see memory `usb-pdm-winusb-path`).

Today that means "clean install to get USB." This spec removes that requirement: the launcher detects
a prefix that lacks the USB bus while running a USB-capable bundle, and migrates it once,
automatically — the same place the launcher already refreshes the patched Wi-Fi DLLs on upgrade.

## Trigger: detect the bus directly — no version/generation bookkeeping

The first draft of this spec used a committed capability-generation integer (`PREFIX_CAPS_GEN` in
`pins.env` vs a `state/prefix-caps` stamp). The review killed that design, correctly:

- The gen is a static committed value, **not coupled to the `INCLUDE_USB` CI flag**. When USB merges
  to `main`, every stable release builds from the same `pins.env`. If stable ships `gen=1`, a fresh
  *stable* install would stamp `prefix-caps=1` **without ever registering the bus** (stable has no
  `wineusb.so`); a later upgrade to a USB build (also gen 1) sees `gen == gen` → no migration → **USB
  silently never works on the machine that most needs it** — the stable→USB upgrade is the *primary*
  path the feature exists to serve.
- The gen's only job is to answer "does this prefix need the bus planted?" — which the prefix's own
  registry already records. The whole gen + stamp + pins-coupling surface exists to recompute
  something we can read directly.

**So the trigger is the postcondition itself:**

```text
on launch, RS3 not running, holding the migrate lock:
    if bundle_has_usb and not bus_registered(PREFIX):
        migrate_prefix()
    # else: nothing to do
```

- `bundle_has_usb` — the bundle ships `lib/wine/x86_64-unix/wineusb.so` (only USB builds do). Gates
  the whole thing off for stable bundles, mirroring the `INCLUDE_USB` build gate.
- `bus_registered(PREFIX)` — the same check `verify_caps` would have done: the prefix's `system.reg`
  contains the `wineusb` service key **and** an `Enum\Root\WINEUSB` device node. (Exact key paths get
  pinned from a known-good fresh USB prefix during implementation — do not hardcode a guessed path.)

This is idempotent (once the bus exists, `bus_registered` is true forever → never re-runs),
self-healing, needs **zero** persisted gen/stamp state, and is immune to both gen failure modes above:
a stable install simply never has the bus and never pretends to. It also satisfies Simplicity
Enforcement — it deletes an entire state-management surface. Fresh USB installs are covered for free:
`phase_make_prefix` already planted the bus, so `bus_registered` is true and the launcher does nothing.

### Bounding the retry (the cost of dropping the stamp)

With no success-stamp, a prefix where migration *fails to plant the bus* would re-run the migration on
**every launch forever** — and the migration spawns a `wineboot --init` (or, for the fallback, a
minutes-long rebuild). For users on whom the feature failed, that's a silent per-launch latency
regression with zero payoff. So keep one tiny piece of state — a **failure counter**, not a success
stamp:

```text
# ALL of the following runs AFTER acquiring the migrate lock and re-checking pgrep (see Concurrency),
# so the read→compare→increment is atomic across racing launches — otherwise two applets could both
# read attempts=1, both pass <MAX, and double-migrate (the exact race the lock exists to prevent).
attempts = read_int($STATE_DIR/usb-migrate-attempts)        # missing/garbage → 0
last_bundle = read($STATE_DIR/usb-migrate-bundle)           # the bundle id that last failed
this_bundle = <bundle CFBundleVersion + a USB_MIGRATION_IMPL_REV constant>
if this_bundle != last_bundle:                              # a different/fixed bundle → fresh chances
    attempts = 0
if bundle_has_usb and not bus_registered(PREFIX) and attempts < MAX_ATTEMPTS:   # MAX_ATTEMPTS = 2
    persist attempts+1 AND this_bundle BEFORE migrating     # so a hard crash mid-migrate still counts
    migrate_prefix()
    if bus_registered(PREFIX):
        rm $STATE_DIR/usb-migrate-attempts $STATE_DIR/usb-migrate-bundle      # success → clear
    else:
        log loudly "USB migration attempt N/MAX failed for bundle <this_bundle>"
```

`read_int` must default to 0 on missing **or non-numeric** content (`[[ $x =~ ^[0-9]+$ ]] || x=0`) so
a corrupt file can't trip `set -u`/`set -e` arithmetic. After `MAX_ATTEMPTS`, give up quietly (one log
line that **names the bundle/Wine version**, so support can see why USB didn't migrate), launch
normally; USB stays unavailable but the launch is fast again.

The counter is keyed to a **bundle migration identity** (app `CFBundleVersion` + a bumpable
`USB_MIGRATION_IMPL_REV` constant), not global: a prefix that exhausted its attempts on a buggy USB
build X will retry afresh under a later build Y that ships a fixed migration path. This recovers the
"new bundle should get new chances" property **without** re-introducing the gen/stamp false-positive —
because there is still no *success* stamp; a stable install can never mark itself "capable" without
actually registering the bus (there's nothing to stamp). It's a *failure*-attempt ledger keyed to the
thing that might fix the failure.

## Where the code lives

- **`installer-core.sh` — new action `migrate-prefix`** (+ a `phase_migrate` helper). It reuses
  `run_wine` / `wineserver_wait` / `wineserver_kill` / `apply_macdrv_keys` and logs to `$LOG`. This is
  the only place that spawns Wine for the migration, and the only place that reads/writes the attempt
  counter and reads `system.reg`. Wire a dispatch case at the bottom (next to `is-installed`).
- **`RaceStudio3.applescript` — a new, separate `do shell script` statement in `launchRS3`**, placed
  **before** the existing hygiene `do shell script sh`, NOT spliced into the `hygiene` string. (The
  hygiene block is one big shell string; the migration is its own AppleScript statement with its own
  error swallow.) It must:
  - run only when `! pgrep -f 'AiMRS3-64'` (RS3 GUI not up) — re-checked inside the lock too;
  - be best-effort (`try … on error … end try`, or `|| true`) — a migration failure can never stop RS3
    from opening;
  - **pass `RS3_WINE_BIN`** — see the next section; this is load-bearing.

### CRITICAL plumbing: migration needs the bundle's Wine binary

Do **not** model the invocation on `isInstalled` (applescript:181), which shells `installer-core.sh`
*without* `RS3_WINE_BIN` because `is-installed` never spawns Wine. In the bundled-app flow Wine lives
in `Contents/Resources/wine`, and `installer-core.sh` only resolves `WINE_BIN` from there when
`RS3_WINE_BIN` is passed (installer-core.sh:81–85). Migration spawns Wine, so it must be invoked like
`runCoreAsync` (applescript:226):

```sh
RS3_SINGLE_APP=1 RS3_WINE_BIN=<wineBin()> UI_MODE=applet <installer-core.sh> migrate-prefix
```

Modeled on `is-installed` instead, `WINE_BIN` comes up empty → the migration `die`s "internal: Wine not
installed" → fails **every launch, silently** (best-effort) → USB never works. Must use the *bundle's*
Wine specifically: that's the binary whose `lib/wine/` carries the new `wineusb.so`.

### Concurrency: a lock, because the pgrep guard has a race

`! pgrep -f 'AiMRS3-64'` only proves the GUI isn't up *yet* — there's a multi-second window during
launch before the process registers, and users double-click when the first click "seems to do
nothing." Two applets can both pass the guard and run two concurrent `wineboot --init` on the same
prefix → corruption. Wrap the migration in an exclusive lock under `$STATE_DIR` (e.g. `mkdir`-based
lock or `flock` on `$STATE_DIR/usb-migrate.lock`), **re-check `pgrep` after acquiring the lock**, and
release on exit (trap). The existing DLL-refresh hygiene shares the window but is idempotent `cp`;
racing inits are not, so this lock is specific to the migration.

### Data safety (unchanged hard rule)

The migration must never touch user data. The user's telemetry/data lives in `AIM_SPORT` (outside
Wine's system dirs) via the `…/RaceStudio3/user` symlink — `wineboot` writes only `drive_c/windows` +
the registry, so that data is safe (confirmed). Re-assert the `data_relocate_safe` hard rule in the
implementation review. **Approach C below is the exception that needs special care — see its caveat.**

## The migration mechanism (the load-bearing unknown — bench first, in this order)

**A. Re-run `wineboot --init` in place — try first, but expect it to fight back.**
The cheapest, most Wine-native option: `wineboot --init` reprocesses the bundled `*.inf` (now incl.
`wineusb.inf`), the same path that plants the bus on a fresh prefix. **But `wineboot` is optimized to
skip work it thinks is already done** — `-u` already failed in earlier tests, and a plain `--init` on
an already-initialized prefix may short-circuit `wineusb.inf` processing too. Bench checklist:
- Does a second `--init` actually create the `wineusb` service + `root\WINEUSB\0` node the first
  (libusb-less) init omitted? If it short-circuits, test **coercing re-evaluation** by clearing Wine's
  init markers (e.g. the prefix `.update-timestamp`, or the relevant `HKLM\Software\Wine` config keys)
  before the `--init`. Note: a previous session found the `.update-timestamp` "disable" magic value
  broke in-app updates — so strip/blank it carefully and verify updates still work, or prefer B.
- **Diff `system.reg` AND `user.reg` before/after** (not just grep for the `wineusb` key). A second
  `--init` on a prefix with RS3 already installed reprocesses `wine.inf` and can churn file
  associations, uninstall entries, and other HKLM/HKCU state RS3 wrote at `silent-install`. Confirm the
  churn is benign before shipping A.
- Re-apply anything `--init` resets that we rely on: at minimum `apply_macdrv_keys` (Cmd→Ctrl). The
  launcher already re-applies the VLC vout prune and Wi-Fi DLL refresh each launch.
- Run under the watchdog (`WINEBOOT_TIMEOUT`), then `wineserver_wait` before checking `bus_registered`.

**B. Targeted device install via setupapi — the preferred fallback (surgical, preserves user state).**
Install just the bus device from `wineusb.inf` without a full re-init, e.g.
`rundll32 setupapi.dll,InstallHinfSection <DefaultInstall-section> 128 <path>\wineusb.inf`. This
modifies only the driver store + the device/service registry entries and **leaves `user.reg`,
`system.reg`'s unrelated keys, and `AppData` intact** — no settings churn. The exact section name and
arguments must be confirmed against Wine 11.9's `wineusb.inf`. Because it's surgical, prefer B over C
whenever A is unviable.

**C. Rebuild-beside + relink — LAST resort, and NOT a transparent "known-good fallback".**
The first draft called this "known-good." That was wrong. Swapping the whole prefix is a *clean
reinstall from the Windows environment's perspective*: it discards `system.reg`/`user.reg` (window
positions, recent files, device history, software activation/registration state) and
`drive_c/users/*/AppData` (caches, `.ini`s RS3 may write). For a user upgrading in place, that's a
silent settings reset. Only use C if BOTH A and B fail on the bench, and only with one of:
  (a) a state-migration pass that copies the old prefix's `user.reg` + relevant `AppData` into the new
      prefix after init (and re-applies our DLL/menu patches), or
  (b) an explicit, accepted decision that migrating users get a Windows-side settings reset (their
      *telemetry/data* in `AIM_SPORT` is untouched — but that's not the same as "lossless").
If C is used at all, the swap must be crash-safe (the bare double-`mv` is not):
- back up to a **unique** name, asserting it doesn't already exist (a prior failed attempt could leave
  one — never overwrite it): `bak="$PREFIX.old.$$"; [ -e "$bak" ] && abort`.
- ensure `$PREFIX.new` and `$PREFIX` are on the **same filesystem** (rename is only atomic within one).
- **rollback on failure**: if `mv "$PREFIX.new" "$PREFIX"` fails after `mv "$PREFIX" "$bak"`, immediately
  `mv "$bak" "$PREFIX"` back — the window where no `$PREFIX` exists must be closed.
- **startup recovery**: if a launch finds `$PREFIX` missing but a `$PREFIX.old.*` present, restore it
  before doing anything else (covers a crash inside the window).
- delete the backup **only after** `bus_registered(new)` verifies.
- check `MIN_FREE_GB` free space first — C doubles the prefix on disk plus MSI unpack; the existing
  free-space check is install-time preflight only.

Recommendation: bench A (with the marker-stripping sub-test); if it cleanly plants the bus with benign
registry churn, ship A. Else ship **B**. Treat C as the documented-but-avoided last resort.

## Downgrade (USB build → later stable build)

A stable bundle ships **no** `wineusb.so`, so `bundle_has_usb` is false → the launcher does nothing,
correct. Note the prior prefix still has the `wineusb` **service registered** but the bundle no longer
ships the driver `.so`/`.sys` in `lib/wine/` — so the service *fails to load* rather than being absent.
Almost certainly benign (winusb just finds no devices), but the bench must confirm there's no
per-launch error spew in the Wine log. (This corrects the first draft's "driver only loads when its
service is registered, which a stable bundle leaves alone" — the service IS registered; it's the
binary that's gone.)

## Test plan

- **Unit (`installer/test/`)** — a `migrate-prefix` decision test against a stubbed prefix + bundle
  (no real Wine), covering:
  - no-op when `bundle_has_usb` is false (stable bundle), even if the bus is absent;
  - no-op when `bus_registered` is true (already migrated / fresh USB install);
  - runs when `bundle_has_usb && !bus_registered && attempts < MAX`;
  - **attempt cap**: stops after `MAX_ATTEMPTS`, counter survives, no spawn on the (MAX+1)th launch;
  - **bundle-keyed reset**: a prefix at `attempts=MAX` under bundle X gets a fresh `attempts=0` when
    `usb-migrate-bundle` shows a different bundle id (Y) — so a fixed newer build retries;
  - **counter parse hardening**: missing / empty / non-numeric `usb-migrate-attempts` → treated as 0,
    no `set -u`/`set -e` abort;
  - **lock**: a second invocation while the lock is held is a no-op (doesn't double-run).
- **Bench (manual, the decision gate)** — copy a real pre-USB prefix; run A (with and without
  marker-stripping); diff `system.reg`+`user.reg`; confirm the `wineusb` service + `root\WINEUSB`
  node appear and enumeration sees USB. Decide A vs B (vs C) from this. If C is reached, test the
  crash-safe swap + rollback + startup-recovery paths explicitly (kill between the two `mv`s).
- **End-to-end (on hardware, the real gate)** — a Mac with an existing Wi-Fi/SD install, upgrade to the
  USB build, launch once (migration fires), plug in a PDM, confirm RS3 enumerates it and pushes a
  config (`WinUsb_WritePipe`, write-heavy) — without ever uninstalling.
- **Regression** — a stable→stable upgrade spawns no Wine (instant launch); an already-migrated USB
  user sees `bus_registered` true and skips; a failed-migration prefix stops after `MAX_ATTEMPTS`.

## Security

The only new user-influenced input is `$STATE_DIR/usb-migrate-attempts` (user-writable). It flows into
an integer compare only — never `eval`'d or unquoted into a command — and is parse-hardened to 0 on any
non-numeric content. No shell-injection vector. Pin this in the implementation review.

## Out of scope / explicitly not doing

- No success-stamp / capability-generation file (deleted from the design — `bus_registered` is the
  trigger). The only persisted state is the bounded failure counter.
- No `bin/launch.sh` coverage: it's the dead-code non-applet launcher (CLAUDE.md), and like the DLL
  refresh it won't carry the migration — stated here so the two don't appear to silently drift.
- No re-migration on a *newer* USB bundle generation (there's only one USB capability today; revisit
  if a second arrives).

## References

- Launcher / DLL-refresh precedent + the `RS3_WINE_BIN` call shape:
  `installer/src/RaceStudio3.applescript` (hygiene ~L87–97; `runCoreAsync` L226; `isInstalled` L181).
- Prefix creation: `installer/src/installer-core.sh::phase_make_prefix`; bundled-Wine resolution
  L81–85; Wine helpers in `lib/wine.sh`.
- Ledger marker+postcondition pattern: `installer/src/lib/ledger.sh`.
- Why in-place retrofit failed before: memory `usb-pdm-winusb-path`; USB build: PR #24.
- This spec was revised after a codex/gemini/opus multi-model review (2026-06-18): trigger changed
  from capability-gen to direct bus detection (fixes the stable→USB upgrade break), `RS3_WINE_BIN`
  plumbing made explicit, retry bounded, lock added, Option C demoted below setupapi with a data-loss
  caveat, swap made crash-safe.
