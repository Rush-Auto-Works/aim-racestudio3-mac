# Manual test scenarios

Automated coverage lives in `test/` (`run-all.sh` for unit + dry-run, `e2e-local.sh` for a real
offline install). This file is the human checklist for the things a script can't fully assert —
mostly the GUI and the live-hardware paths.

## Automated (run these — no clicks)
- `bash installer/test/run-all.sh` — validators, net resume, ledger postconditions, preflight,
  the full `data_relocate_safe` state machine (clean / migrating / every resume + crash branch /
  merge-blocked abort / import), launcher generation, and `--dry-run` (no network, no stray writes).
- `bash installer/test/e2e-local.sh` — REAL Wine download(cached)+extract, real `wineboot`, real
  silent RS3 install, atomic relocate, `--repair` resume, and data-preservation across `--reinstall`.
  Fully offline (pre-seeds the cache from the verified local artifacts). Several minutes under Rosetta.

## Manual — clean install (GUI)
1. On a Mac with no prior install and no `~/Documents/AIM_SPORT`: double-click `Install RaceStudio 3.app`.
2. Expect: welcome dialog → progress through 8 steps → done dialog. No Terminal window. No Gatekeeper
   prompt (notarized).
3. Launch from `~/Applications/RaceStudio 3.app`. RS3 opens and **renders cleanly** (no garbled text).

## Manual — migrating user (the data-safety case)
1. Pre-populate `~/Documents/AIM_SPORT` with real configs + `.xrk`.
2. Install. Confirm afterwards every pre-existing file is byte-identical (nothing overwritten) and
   `…/prefix/drive_c/AIM_SPORT/RaceStudio3/user` is a symlink to `~/Documents/AIM_SPORT`.

## Manual — upgrading to a DMG that ships a newer RaceStudio 3
1. Start from a Mac with an older RS3 installed (check with
   `sed -n 's|.*<p n="VERSION">\(.*\)</p>.*|\1|p' ~/Library/Application\ Support/RaceStudio3/prefix/drive_c/AIM_SPORT/RaceStudio3/RaceStudio3.xmv`).
   Identify the data folder — it may be `~/Documents/AIM_SPORT` or `~/AIM_SPORT` — and capture
   its file hashes before upgrading: set `DATA_DIR` to whichever folder exists, then run
   `find "$DATA_DIR" -type f -exec shasum {} + | sort > /tmp/before.txt`.
2. Quit RaceStudio 3. Install the newer DMG over the top (drag, replace).
3. Launch `RaceStudio 3.app`. Expect the **"This version of the app installs a newer RaceStudio 3"**
   dialog — NOT the first-run welcome, and NOT a straight launch of the old version.
4. Click Update. Expect the installer to be acquired (downloaded, or reused from the cache if a
   verified copy is already there), then RS3 to install, followed by "RaceStudio 3 is up to date."
   To specifically exercise the download path, first remove
   `~/Library/Application Support/RaceStudio3/installer/RaceStudio3-64_*.exe`.
5. Re-run the command from step 1 and compare it with `RS3_PINNED_VER` in
   `installer/src/pins.env`. This prints a concrete yes/no result (AiM's equivalent trailing
   `.0` is accepted):
   `installed="$(sed -n 's|.*<p n="VERSION">\(.*\)</p>.*|\1|p' ~/Library/Application\ Support/RaceStudio3/prefix/drive_c/AIM_SPORT/RaceStudio3/RaceStudio3.xmv)"; pinned="$(sed -n 's/^RS3_PINNED_VER="\(.*\)"/\1/p' installer/src/pins.env)"; if [ "$installed" = "$pinned" ] || [ "${installed%.0}" = "$pinned" ]; then echo YES; else echo NO; fi`
6. Open "Show RaceStudio 3 Logs" and confirm `system-info.txt` reports `RS3 version (installed):`
   matching `RS3 version (pinned):` with no mismatch warning.
7. Confirm the data folder is byte-identical: with the same `DATA_DIR` as step 1, run
   `find "$DATA_DIR" -type f -exec shasum {} + | sort > /tmp/after.txt; if diff -q /tmp/before.txt /tmp/after.txt >/dev/null; then echo YES; else echo NO; fi`.
   The result must be YES; sessions and configs should also still be listed in RS3.
8. Launch the app once more — it must go straight to RaceStudio 3 with no dialog.

## Manual — declining an available RS3 update
1. Restore the older RS3 installation (or reinstall the older DMG) so its manifest is older than
   `RS3_PINNED_VER` in the newer DMG's `installer/src/pins.env`. Quit RaceStudio 3.
2. Launch the newer DMG's `RaceStudio 3.app`. Expect the **"This version of the app installs a
   newer RaceStudio 3"** dialog.
3. Click **Not Now**. It must open the RaceStudio 3 already installed, and that app must remain
   usable; do not click Update in this scenario.

## Manual — interrupts
1. Quit the installer (or pull the network) mid-Wine-download → re-run → resumes, no corruption.
2. Force-quit during `wineboot` → re-run → prefix redone.
3. Force-quit during relocation → re-run → `data_relocate_safe` resumes from the observed FS state
   with no data loss (the automated state-machine tests cover every branch deterministically).

## Manual — unhappy inputs
- No network at first launch → friendly "couldn't download" dialog (not a Wine stack trace).
- Rosetta missing + Cancel on the admin prompt → clear hard-stop dialog.
- Intel Mac → installs without the Rosetta step.

## Manual — import flows
- Drag an `AIM_SPORT` folder (or a `.zip`, or loose `.xrk`) onto `Import RaceStudio 3 Data.app` →
  merges, never overwrites, shows a summary count.
- Installer's optional "I have a folder" picker → same merge.
- Auto-from-Parallels (`scripts/port-data-from-parallels.sh`) with a running VM.

## Manual — uninstall
- `Uninstall RaceStudio 3.app` → removes engine + launchers; asks separately before deleting
  `~/Documents/AIM_SPORT` (default keep). Prints exactly what was removed.

## Manual — hardware
- AiM device over **WiFi**: connects. Over **USB**: does not (Wine USB passthrough) — documented.
