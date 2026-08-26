> Generated: 2026-06-02 | Token-lean format for LLM context

# Installer Engine — `installer/src/`

Pure-bash, GUI-independent engine. `installer-core.sh` is the orchestrator; `lib/*.sh` are modules;
`pins.env` holds pinned versions/URLs/locations. Runs standalone (CLI) or driven by the AppleScript
applet (`UI_MODE=applet`). Safety: `set -uo pipefail` + single EXIT trap; NO blanket `set -e` around
Wine (benign nonzero exits). Success is judged by **postconditions (ledger)**, not `$?`.

## installer-core.sh (475 lines) — dispatch

Actions: `run` (all 8 phases) · `<phase>` (one phase, applet calls these) · `repair` · `reinstall`
· `import <dir|zip|xrk|drk|zconf2>` · `uninstall` · `set-config` · `is-installed` · `help`.
Flags: `--dry-run` (no net/writes outside sandbox) · `--latest` · `--smoke-test` · `--repair` · `--reinstall` · `--import`.

Phases: `phase_preflight acquire_installer download_wine make_prefix silent_install relocate_data make_launcher done`.
`make_prefix` also calls `apply_macdrv_keys` (wine.sh) post-`wineboot` to set the native keyboard-feel reg keys (Cmd→Ctrl, left Opt→Alt) — best-effort, new prefixes only.
`write_launch_script` / `write_uninstall_script` generate `$INSTALL_ROOT/bin/{launch,uninstall}.sh`.
Actions: `run_all do_repair do_reinstall do_import do_uninstall`.

Key env overrides (used by tests + applet): `RS3_APP_SUPPORT RS3_APPS_DIR RS3_DATA_DIR RS3_WINE_BIN
RS3_SINGLE_APP UI_MODE LAUNCHER_APP_SRC IMPORT_APP_SRC UNINSTALL_APP_SRC`.
`is-installed` requires `ledger_verify installed` AND `bin/launch.sh` executable.

## lib modules

| Module | Key functions | Purpose |
|--------|---------------|---------|
| `data.sh` | `data_relocate_safe` `_merge_copy_if_absent` `_verify_merge` `_find_user_tree` `_dir_has_session_file` `import_merge` `import_session_dir` `import_config_archive` `_find_config_dirs` `_cfg_label` `_cfg_already_imported` `_cfg_free_name` | The #1 data-loss surface. Relocate prefix `user/` → DATA_DIR; merge imports; unpack `.zconf2` configs into `cfgs/`. |
| `ledger.sh` | `ledger_mark/clear/has/verify/done/skip_if_done` | Phase completion markers (`$STATE_DIR/*.ok`) + structural postconditions. |
| `net.sh` | `https_guard` `validate_version` `validate_wine_asset` `file_size` `download_verified` | HTTPS-only downloads with size+sha256 verification. |
| `preflight.sh` | `macos_ok` `is_apple_silicon` `rosetta_present` `rosetta_install_cli` `enough_disk` `icloud_documents_synced` | Environment checks. |
| `ui.sh` | `ui_say/progress/warn/error/persist/recall/choice/confirm` `ui_import_dest` `ui_import_config` `ui_import_config_dup` `ui_import_extras` | Dual CLI/applet UX; applet path emits `NEEDS_*` sentinels + rc. |
| `wine.sh` | `watchdog` `find_wine_binary` `wineserver_path/kill/wait` `run_wine` `wine_env_export` `write_macdrv_reg`/`apply_macdrv_keys` | Wine invocation wrappers (timeouts, prefix env) + native keyboard-feel Mac Driver reg keys. |

## data_relocate_safe state machine (crash-safe, re-entrant)

```
SRC = $PREFIX/drive_c/AIM_SPORT/RaceStudio3/user   DST = $DATA_DIR   GONE = SRC.gone   TMPLINK = SRC.tmplink
resume ladder: (a) SRC already symlink→DST: adopt  (b) TMPLINK present: complete swap  (c) SRC gone + GONE: re-link
               (d) SRC missing + DST exists: bind  else forward path:
forward: disk-check → _merge_copy_if_absent(SRC→DST) → _verify_merge → mv SRC→GONE → ln -s DST tmplink → mv tmplink→SRC (ATOMIC) → rm GONE
```
Invariants: DST made complete+verified BEFORE SRC touched · MERGE = copy-if-absent (user's file wins, never overwrite) · only the disposable GONE is deleted · symlink installed via atomic rename.

Import routing (`do_import`): RS3 user-tree → `import_merge`; folder of loose `.xrk`/`.drk` →
`import_session_dir` (copies into `$DATA_DIR/data/<folder>/`, never overwriting); `.zip` → user-tree
merge OR loose-session copy; single `.xrk`/`.drk` → `$DATA_DIR/data/dropped-<date>/`;
`.zconf2`/`.zconfig` → `import_config_archive`. `.drk` is the legacy RS2-era format; RS3's importer
reads it natively.

Sessions and configurations end differently, and the difference is the whole point of the routing.
RS3 does not scan the data folder, so a staged SESSION appears only after the user runs RS3's own
Import (cogwheel → Import → Import Folder) — it needs a row in `database/data.xrd`. A CONFIGURATION
needs no database row: RS3 lists whatever `cfgs/<cfg_*>` folders it finds on disk, so
`import_config_archive` unpacking the archive there IS the import, and RS3 only has to restart.

Applet contract — five machine-readable lines, all parsed by both `.applescript` files:

| Line | Emitted by | Applet does |
|------|-----------|-------------|
| `IMPORT_DEST: <path>` | staged sessions | points the user at RS3's own Import |
| `IMPORT_CONFIG: <name>` | a configuration that landed | lists it, says to restart RS3 |
| `IMPORT_CONFIG_DUP: <name>` | a configuration already present | lists it as not copied again |
| `IMPORT_EXTRAS: <count>` | shared resources merged | reports the count, suppresses "nothing new" |
| `WARN: <text>` | any recoverable failure | switches the dialog to "finished with problems" |

## launch.sh (generated)

Resolves Wine in `$ROOT/wine`, exports `WINEPREFIX/WINEARCH=win64/WINEDEBUG=-all`,
`WINEDLLOVERRIDES="mscoree=d;mshtml=d"` (no .NET / Gecko), runs `arch -x86_64 <wine> '<RS3 exe>'` detached.
(Bundled mode launches Wine directly from the app bundle via the applet's `launchRS3`, not this script.)

## Tests — `installer/test/`

`bash installer/test/run-all.sh` (unit-{data,ledger,net,preflight,validators,launcher} + unit-pins-online + dryrun-test).
`unit-pins-online.sh` = NETWORK test: HEADs the pinned RS3/Wine URLs, asserts size matches the pin;
skips (77) offline or when `RS3_SKIP_ONLINE=1`. CI (`tests.yml`, macos-14) runs it only on the daily
schedule, not on the PR gate. `e2e-local.sh` = offline real install. `harness.sh` = assert helpers.
