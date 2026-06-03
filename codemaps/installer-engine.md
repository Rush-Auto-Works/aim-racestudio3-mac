> Generated: 2026-06-02 | Token-lean format for LLM context

# Installer Engine — `installer/src/`

Pure-bash, GUI-independent engine. `installer-core.sh` is the orchestrator; `lib/*.sh` are modules;
`pins.env` holds pinned versions/URLs/locations. Runs standalone (CLI) or driven by the AppleScript
applet (`UI_MODE=applet`). Safety: `set -uo pipefail` + single EXIT trap; NO blanket `set -e` around
Wine (benign nonzero exits). Success is judged by **postconditions (ledger)**, not `$?`.

## installer-core.sh (475 lines) — dispatch

Actions: `run` (all 8 phases) · `<phase>` (one phase, applet calls these) · `repair` · `reinstall`
· `import <dir|zip|xrk>` · `uninstall` · `set-config` · `is-installed` · `help`.
Flags: `--dry-run` (no net/writes outside sandbox) · `--latest` · `--smoke-test` · `--repair` · `--reinstall` · `--import`.

Phases: `phase_preflight acquire_installer download_wine make_prefix silent_install relocate_data make_launcher done`.
`write_launch_script` / `write_uninstall_script` generate `$INSTALL_ROOT/bin/{launch,uninstall}.sh`.
Actions: `run_all do_repair do_reinstall do_import do_uninstall`.

Key env overrides (used by tests + applet): `RS3_APP_SUPPORT RS3_APPS_DIR RS3_DATA_DIR RS3_WINE_BIN
RS3_SINGLE_APP UI_MODE LAUNCHER_APP_SRC IMPORT_APP_SRC UNINSTALL_APP_SRC`.
`is-installed` requires `ledger_verify installed` AND `bin/launch.sh` executable.

## lib modules

| Module | Key functions | Purpose |
|--------|---------------|---------|
| `data.sh` | `data_relocate_safe` `_merge_copy_if_absent` `_verify_merge` `_find_user_tree` `_dir_has_xrk` `import_merge` `import_xrk_dir` | The #1 data-loss surface. Relocate prefix `user/` → DATA_DIR; merge imports. |
| `ledger.sh` | `ledger_mark/clear/has/verify/done/skip_if_done` | Phase completion markers (`$STATE_DIR/*.ok`) + structural postconditions. |
| `net.sh` | `https_guard` `validate_version` `validate_wine_asset` `file_size` `download_verified` | HTTPS-only downloads with size+sha256 verification. |
| `preflight.sh` | `macos_ok` `is_apple_silicon` `rosetta_present` `rosetta_install_cli` `enough_disk` `icloud_documents_synced` | Environment checks. |
| `ui.sh` | `ui_say/progress/warn/error/persist/recall/choice/confirm` | Dual CLI/applet UX; applet path emits `NEEDS_*` sentinels + rc. |
| `wine.sh` | `watchdog` `find_wine_binary` `wineserver_path/kill/wait` `run_wine` `wine_env_export` | Wine invocation wrappers (timeouts, prefix env). |

## data_relocate_safe state machine (crash-safe, re-entrant)

```
SRC = $PREFIX/drive_c/AIM_SPORT/RaceStudio3/user   DST = $DATA_DIR   GONE = SRC.gone   TMPLINK = SRC.tmplink
resume ladder: (a) SRC already symlink→DST: adopt  (b) TMPLINK present: complete swap  (c) SRC gone + GONE: re-link
               (d) SRC missing + DST exists: bind  else forward path:
forward: disk-check → _merge_copy_if_absent(SRC→DST) → _verify_merge → mv SRC→GONE → ln -s DST tmplink → mv tmplink→SRC (ATOMIC) → rm GONE
```
Invariants: DST made complete+verified BEFORE SRC touched · MERGE = copy-if-absent (user's file wins, never overwrite) · only the disposable GONE is deleted · symlink installed via atomic rename.

Import routing (`do_import`): RS3 user-tree → `import_merge`; folder of loose `.xrk` → `import_xrk_dir`
(copies into `$DATA_DIR/data/<folder>/`, never overwriting); `.zip` → unzip then merge; single `.xrk` → `$DATA_DIR/data/dropped-<date>/`.

## launch.sh (generated)

Resolves Wine in `$ROOT/wine`, exports `WINEPREFIX/WINEARCH=win64/WINEDEBUG=-all`,
`WINEDLLOVERRIDES="mscoree=d;mshtml=d"` (no .NET / Gecko), runs `arch -x86_64 <wine> '<RS3 exe>'` detached.
(Bundled mode launches Wine directly from the app bundle via the applet's `launchRS3`, not this script.)

## Tests — `installer/test/`

`bash installer/test/run-all.sh` (unit-{data,ledger,net,preflight,validators,launcher} + unit-pins-online + dryrun-test).
`unit-pins-online.sh` = NETWORK test: HEADs the pinned RS3/Wine URLs, asserts size matches the pin;
skips (77) offline or when `RS3_SKIP_ONLINE=1`. CI (`tests.yml`, macos-14) runs it only on the daily
schedule, not on the PR gate. `e2e-local.sh` = offline real install. `harness.sh` = assert helpers.
