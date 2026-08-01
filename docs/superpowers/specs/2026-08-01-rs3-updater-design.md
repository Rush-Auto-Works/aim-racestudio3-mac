# RS3 self-update: version detection, channels, and an updater surface

Date: 2026-08-01
Status: **Part A ready to plan. Part B unblocked 2026-08-01 — both open decisions answered.**
Revised after review round 1 (executor / auditor / antigravity, all REVISE).

## Split: A is a bugfix, B is a feature

Review was unanimous that coupling these was wrong. They now ship separately.

- **Part A — the bug.** DMG upgrades do not update RS3. Self-contained, no new surface,
  no new state. Ship first.
- **Part B — the feature.** Channels and an updater app. Depends on A. Two open decisions
  below must be answered before it can be planned.

---

# Part A: make a DMG upgrade actually update RS3

## Problem

Verified on device 2026-08-01: after installing the `v3.83.39-1` DMG, `state/config.env`
still records `RaceStudio3-64_38326_...exe` and the installer cache holds only that file.
RS3 3.83.39 was never downloaded.

1. **`phase_acquire_installer` (`installer-core.sh:147-148`)** — `if [ -n "$pre" ] && [ -f "$pre" ]`
   returns early without comparing the recalled filename to the target. A stale record wins.
2. **`ledger_verify installed` (`lib/ledger.sh:24`)** — only checks the exe exists and is
   `PE32+`. No version comparison, so `phase_silent_install` skips (`installer-core.sh:253`).
3. **`collect-logs.sh:58`** — reports the version from `pins.env`, not the install, which is
   what hid the bug.

Also: `do_reinstall` removes `"$STATE_DIR"/*.ok` (`installer-core.sh:439`) but not
`config.env`, and leaves `$INSTALLER_CACHE`, so even a full reinstall reinstalls the old RS3.

The `v3.83.39-1` CHANGELOG claim "updates RaceStudio 3 to 3.83.39" is currently true only
for fresh installs.

## Version detection

`prefix/drive_c/AIM_SPORT/RaceStudio3/RaceStudio3.xmv` carries `<p n="VERSION">3.83.26.0</p>`,
written by AiM's installer, so it stays correct even after RS3's in-app updater runs.

`rs3_installed_ver` in `lib/wine.sh`: parse `VERSION`, normalise `3.83.26.0` → `3.83.26`,
return 1 on missing file / missing tag / a value not matching `^[0-9]+(\.[0-9]+){2,3}$`.
Pure, unit-testable.

> Auditor correctly noted the `.xmv` format is an external premise not present in the repo.
> A real captured fixture is committed as part of this work, so the premise becomes testable.

## Version comparison — one comparator, three-way

A single `ver_cmp a b` returning `lt` / `eq` / `gt`, used everywhere. Needed because two
representations exist and a naive compare is wrong:

- release tags are `v${VERSION}-${PKG_REV}` (`build-apps.sh:44`) → `v3.83.39-1`
- bundles write `CFBundleVersion` as `${VERSION}.${PKG_REV}` (`build-apps.sh:295`) → `3.83.39.1`

Comparing those directly falsely reports an update. The comparator normalises both.

## The fixes

**`phase_acquire_installer`** — accept a recalled `INSTALLER_EXE` only if its basename equals
the target *and* it passes size+sha. Reviewers were right that basename alone still accepts a
same-named corrupt file; the GUI `choose file` path (`RaceStudio3.applescript:287-292`) copies
without validation, and the Downloads fallback checks size only (`installer-core.sh:176-181`).
All three paths get the same size+sha gate.

**`ledger_verify installed`** — satisfied means `rs3_installed_ver >= target`, not `==`.
Equality-only would make an installed 3.84.0 against a 3.83.39 pin look unsatisfied and
trigger an automatic downgrade, which `ledger_skip_if_done`'s boolean result
(`lib/ledger.sh:42`) cannot express. `>=` is what makes "never downgrade automatically" true.

**`collect-logs.sh`** — report installed and pinned separately. It embeds no `lib/`
(`build-apps.sh:326-331`), so it needs its own small parser rather than sourcing
`rs3_installed_ver`. Duplicated deliberately; both are covered by the same fixture test.

**Prefix claim corrected.** An earlier draft said a failed install leaves the prefix
untouched. That is false — `phase_silent_install` writes into the prefix
(`installer-core.sh:259-268`) with no staging or rollback. The accurate statement: a failed
install leaves the prefix in an undefined state, the `installed` marker cleared, and `repair`
as the recovery path. `$DATA_DIR` is unaffected.

## Testing

Unit, added to `run-all.sh`, each with a mutation check:
- `rs3_installed_ver`: real fixture, missing file, malformed XML, three-field and four-field
  values
- `ver_cmp`: lt/eq/gt, `v3.83.39-1` vs `3.83.39.1`, unequal field counts
- `phase_acquire_installer` rejects a stale basename, rejects a matching basename with wrong
  size, accepts a valid one
- `ledger_verify installed`: older → false, equal → true, newer → true, unknown → false

Manual (`scenarios.md`): a real DMG upgrade over an older install moves RS3.

## Consequence

DMG upgrades stop being instant. Whenever the pin moved they download ~350MB and run the
MSI. That is the cost of the CHANGELOG claim being true.

---

# Part B: channels and an updater surface

Unblocked 2026-08-01. Both decisions below are settled; Part B can be planned after A ships.

## DECIDED 1 — `latest` resolves through a CI-published `latest.json`

All three reviewers, independently. `download_verified` requires an expected size
(`lib/net.sh:58`) and rejects a mismatch (`net.sh:88`). `check-rs3-update.sh` emits only
`version`, `file`, `url` (`check-rs3-update.sh:59`); it computes size and sha **only after**
downloading, behind the `--apply` guard (`check-rs3-update.sh:62`). So a runtime `latest`
cannot call the existing verified-acquisition path at all.

Antigravity added the reliability argument: a client that scrapes AiM's page breaks for every
`latest` user at once the day AiM changes their markup.

**Decided (user, 2026-08-01):** clients never scrape and never download unverified. CI
publishes a static, schema-controlled `latest.json` (version, file, url, size, sha256) as a
release asset; the client reads that and feeds it to the unchanged `download_verified`. This
keeps the integrity chain intact and moves the fragile scraping to CI where a break is visible
to us, not to users.

## DECIDED 2 — keep kill-and-relaunch

**Decided (user, 2026-08-01):** confirm, then `wineserver_kill`, update, relaunch. The user
reaffirmed this after antigravity's data-integrity objection (a hard kill mid-write can corrupt
the config database in `~/AIM_SPORT`, and a confirmation dialog does not prove RS3 is idle).
The objection is recorded, not adopted.

Independently of that choice, the reviewers were right that the **order was wrong**: the draft
killed RS3 *before* acquiring the installer, so a failed download would destroy a live session
for nothing. Acquisition and verification now always happen first; RS3 is only touched once the
payload is on disk. That is fixed regardless of how OPEN 2 resolves.

## Findings already folded in

- **Updater has no Wine.** Aux apps embed core, pins and lib but no Wine
  (`build-apps.sh:317-324`), and `$INSTALL_ROOT/wine` is deliberately not created when
  `RS3_WINE_BIN` is set (`installer-core.sh:197`). The updater must resolve
  `RaceStudio 3.app/Contents/Resources/wine/bin/wine` and pass `RS3_WINE_BIN`, as the main app
  does (`RaceStudio3.applescript:236`).
- **Confirmation cannot carry the warning.** Applet mode emits only `NEEDS_CONFIRM: <key>`
  (`lib/ui.sh:103`) and the UI renders a fixed "Please confirm to continue."
  (`RaceStudio3.applescript:294`). Worse, `ui_confirm` auto-accepts a persisted prior `yes`
  (`lib/ui.sh:100`), so one past downgrade would authorise every future one. A downgrade needs
  a structured `from`/`to` payload rendered by the updater itself, and a one-shot confirmation
  keyed to the version pair — never the sticky one.
- **Channel resolution must survive phase boundaries.** The applet runs each phase as a
  separate core process (`RaceStudio3.applescript:55-57`); only `config.env` crosses that
  boundary (`installer-core.sh:75`). The resolved target tuple is persisted, not recomputed.
- **Fail closed.** There is no `set -e` (`installer-core.sh:19`) and `run_all` ignores phase
  return codes (`installer-core.sh:415-423`), so a failed `latest` resolution would fall
  through to the pinned path. The resolver must `die`, not return nonzero.
- **Single-writer lock.** `download_verified` uses one shared `$dest.partial`
  (`lib/net.sh:63`) and the RS3 download timeout is 40 minutes (`pins.env:51`), so two updater
  launches can race and the user can relaunch RS3 mid-update. The update takes a lock spanning
  acquisition through relaunch.
- **Distribution is more than osacompile.** A fourth app needs compile, resource embedding,
  branding, signing, notarization, pkg staging (`build-apps.sh:443-446`) and DMG staging
  (`build-apps.sh:480-484`). The native menu beeps if the named `.app` is absent
  (`winemac-native-menu.patch:16-28`), so a partial wiring ships a menu item that fails.
- **No GitHub API for the update check.** Unauthenticated REST is 60 req/hour/IP; a paddock
  sharing one hotspot exhausts that. Use a `HEAD` against `/releases/latest` and read the
  `Location` redirect, which costs no quota.

## Implementation order

Part A: `rs3_installed_ver` + `ver_cmp` and tests → `collect-logs` reporting → the two
short-circuit fixes → `scenarios.md` + CHANGELOG. Independently shippable; fixes the
reported bug.

Part B: plan after A ships, against the two decisions above.
