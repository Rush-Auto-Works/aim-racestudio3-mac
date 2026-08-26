# lib/data.sh — the #1 data-loss surface. Relocate the prefix's fresh user/ defaults out to
# the chosen DATA_DIR and replace user/ with a symlink, WITHOUT ever risking the migrating
# user's real telemetry that may already live in DATA_DIR.
#
# Invariants the 5-reviewer debate locked in:
#   * DATA_DIR (DST) is made COMPLETE and VERIFIED before SRC is ever touched.
#   * MERGE is copy-if-absent: we never overwrite a file already in DST (the user's data wins;
#     a newer RS3's required default files are supplied only where DST lacks them). Never rm -rf DST.
#   * The user/ dir is replaced by the symlink via an ATOMIC rename (mv -f tmplink -> SRC).
#   * Only SRC.gone (a disposable copy whose every file is already in DST) is ever deleted.
#   * Fully re-entrant: a crash at ANY point resumes correctly from the observed FS state.
#
# Names:  SRC = $PREFIX/drive_c/$RS3_REL_USER   (fresh defaults from silent install)
#         DST = $DATA_DIR                        (chosen data dir; may already hold real data)
#         SRC.gone     = disposable old SRC dir (post-copy)
#         SRC.tmplink  = the symlink mid-swap

# ---- helpers -------------------------------------------------------------------------------

# avail_kb_for <path> : free KB on the volume holding the nearest existing ancestor of <path>.
_avail_kb_for() {
  local p="$1"
  while [ ! -e "$p" ] && [ "$p" != "/" ]; do p="$(dirname "$p")"; done
  df -Pk "$p" 2>/dev/null | awk 'NR==2 {print $4}'
}

# _MERGED_COPIED holds the relpaths copied by the most recent _merge_copy_if_absent call, so
# _verify_merge can size-check ONLY the files we wrote (where truncation is possible) and not
# pre-existing user files (whose size legitimately differs — that's the whole point of
# copy-if-absent: the user's version wins).
_MERGED_COPIED=()

# _merge_copy_if_absent <src> <dst> : for every file under src, if dst lacks it, copy it in
# via a per-file atomic commit (temp name + mv) so a crash mid-copy can't leave a truncated
# file that copy-if-absent would then skip forever. Existing dst files are NEVER overwritten.
_merge_copy_if_absent() {
  local src="$1" dst="$2" rel d tmp
  _MERGED_COPIED=()
  mkdir -p "$dst"
  # Recreate directory structure first (dirs are cheap and idempotent).
  while IFS= read -r d; do
    mkdir -p "$dst/${d#./}"
  done < <(cd "$src" && find . -type d)
  # Copy files that are absent in dst.
  while IFS= read -r rel; do
    rel="${rel#./}"
    # `-e` alone is not "absent": it is false for a DANGLING symlink, so a user's link whose target
    # is offline (an unmounted volume, a moved folder) read as missing and `mv -f` replaced it with
    # a regular file. `-L` closes that hole.
    if [ ! -e "$dst/$rel" ] && [ ! -L "$dst/$rel" ]; then
      # mktemp, not "$rel.tmp.$$": the PID name is predictable, so a leftover from a crashed
      # import (or a user file that simply happens to be called that) would be clobbered by the
      # ditto and then deleted by the mv. mktemp creates its file exclusively, so it can never
      # land on a name that already exists.
      tmp="$(mktemp "$dst/$rel.tmp.XXXXXX")" || return 1
      ditto "$src/$rel" "$tmp" || { rm -f "$tmp"; return 1; }
      # Committing the copy is two guards, because neither alone is enough. The re-test catches a
      # destination that appeared while ditto ran — including a DIRECTORY, which both `ln` and `mv`
      # would descend into, dropping the temp inside and reporting success. `ln` then does the
      # commit, failing with EEXIST rather than clobbering if a plain file beat us to it. That
      # leaves a two-syscall window in which a directory could still appear; it is not airtight,
      # and it is as close as portable shell gets without a rename-if-absent syscall.
      if [ -e "$dst/$rel" ] || [ -L "$dst/$rel" ]; then
        rm -f "$tmp"                       # lost the race; whatever is there is the user's and wins
      elif ln "$tmp" "$dst/$rel" 2>/dev/null; then
        _MERGED_COPIED+=("$rel")
        rm -f "$tmp"
      else
        rm -f "$tmp"
        # Something occupying the destination is the expected loss of that race. Anything else
        # means the copy really failed and the caller must hear about it.
        [ -e "$dst/$rel" ] || [ -L "$dst/$rel" ] || return 1
      fi
    fi
  done < <(cd "$src" && find . -type f)
}

# _verify_merge <src> <dst> : EVERY file in src must be present in dst (the load-bearing gate —
# guarantees the symlink won't lose any default RS3 needs). For files WE copied this run, also
# require an exact size match (truncation insurance); a zero-byte src => zero-byte dst is fine.
# Pre-existing dst files are NOT size-checked — the migrating user's data is authoritative.
_verify_merge() {
  local src="$1" dst="$2" rel ssz dsz
  while IFS= read -r rel; do
    rel="${rel#./}"
    [ -e "$dst/$rel" ] || { ui_warn "verify: missing in DST: $rel"; return 1; }
  done < <(cd "$src" && find . -type f)
  for rel in ${_MERGED_COPIED[@]+"${_MERGED_COPIED[@]}"}; do
    ssz="$(stat -f %z "$src/$rel" 2>/dev/null || echo -1)"
    dsz="$(stat -f %z "$dst/$rel" 2>/dev/null || echo -2)"
    if [ "$ssz" != "$dsz" ]; then ui_warn "verify: copied file truncated: $rel ($ssz vs $dsz)"; return 1; fi
  done
  return 0
}

# ---- the state machine ---------------------------------------------------------------------

data_relocate_safe() {
  local SRC="$PREFIX/drive_c/$RS3_REL_USER"
  local DST="$DATA_DIR"
  local GONE="$SRC.gone"
  local TMPLINK="$SRC.tmplink"

  # ===== RESUME LADDER: branch on observed FS state first ===================================

  # (a) SRC already the symlink. Adopt only if it points at the CURRENT DST (stale-target guard).
  if [ -L "$SRC" ]; then
    if [ "$(readlink "$SRC")" = "$DST" ]; then
      rm -rf "$GONE" 2>/dev/null || true        # post-rename-crash leftover hygiene
      ledger_mark data; return 0
    fi
    ui_warn "user/ symlink points to a stale data dir; replacing"
    rm -f "$SRC"                                  # fall through to rebuild against current DST
  fi

  # (b) tmplink present (crashed between ln and the atomic rename). Adopt only if target==DST.
  if [ -L "$TMPLINK" ]; then
    if [ "$(readlink "$TMPLINK")" = "$DST" ] && [ ! -e "$SRC" ]; then
      mv -f "$TMPLINK" "$SRC"                     # atomic completion of the swap
      rm -rf "$GONE" 2>/dev/null || true
      ledger_mark data; return 0
    fi
    rm -f "$TMPLINK"                              # stale/ambiguous -> discard, rebuild
  fi

  # (c) SRC gone but GONE survives (crashed after mv SRC->GONE, before/at symlink). DST already
  #     holds everything (it was verified before the move). Re-create the symlink.
  if [ ! -e "$SRC" ] && [ -d "$GONE" ]; then
    ln -s "$DST" "$TMPLINK"
    mv -f "$TMPLINK" "$SRC"
    rm -rf "$GONE" 2>/dev/null || true
    ledger_mark data; return 0
  fi

  # (d) SRC missing entirely and DST exists (defensive: install made no user/, or fully cleaned
  #     up). Just bind the symlink.
  if [ ! -e "$SRC" ] && [ -d "$DST" ]; then
    ln -s "$DST" "$TMPLINK"; mv -f "$TMPLINK" "$SRC"
    ledger_mark data; return 0
  fi

  # If SRC is missing and DST is missing, there is nothing to relocate — that is a real error.
  if [ ! -e "$SRC" ]; then
    ui_error "user data dir missing in prefix and no $DST to bind"; return 1
  fi

  # ===== FORWARD PATH: SRC is a real directory =============================================

  # 0. disk check sized by ACTUAL data (× 1.2 headroom), on DST's volume.
  local need_kb avail_kb
  need_kb="$(du -sk "$SRC" 2>/dev/null | awk '{print $1}')"
  need_kb=$(( need_kb * 12 / 10 ))
  avail_kb="$(_avail_kb_for "$DST")"
  if [ -n "$avail_kb" ] && [ "$avail_kb" -lt "$need_kb" ] 2>/dev/null; then
    ui_error "not enough space to relocate data: need ~${need_kb}KB, have ${avail_kb}KB on $(dirname "$DST")"
    return 1
  fi

  # 1. make DST authoritative AND complete (copy-if-absent merge), then VERIFY before touching SRC.
  ui_say "Securing your data folder ($DST) — your existing files are never overwritten."
  _merge_copy_if_absent "$SRC" "$DST" || { ui_error "failed to populate $DST"; return 1; }
  _verify_merge "$SRC" "$DST"          || { ui_error "verification of $DST failed; leaving original data untouched"; return 1; }
  ledger_mark data.copied

  # 2. atomically replace SRC (real dir) with a symlink -> DST. Only the disposable GONE is deleted.
  rm -rf "$GONE" 2>/dev/null || true     # hygiene: a leftover GONE must not make mv nest inside it
  mv "$SRC" "$GONE"                       # SRC.gone is disposable: every file already in DST
  ln -s "$DST" "$TMPLINK"
  mv -f "$TMPLINK" "$SRC"                  # ATOMIC: SRC is now the symlink
  rm -rf "$GONE" 2>/dev/null || true
  ledger_mark data.symlinked
  ledger_mark data
  return 0
}

# _find_user_tree <dir> : echo the RaceStudio3 "user" folder inside <dir> (the dir itself if it IS
# one, else a RaceStudio3/user or AIM_SPORT/RaceStudio3/user under it), or nothing if none.
_find_user_tree() {
  local in="$1"
  if [ -d "$in/cfgs" ] || [ -d "$in/system" ] || [ -d "$in/profiles" ]; then echo "$in"
  elif [ -d "$in/RaceStudio3/user" ]; then echo "$in/RaceStudio3/user"
  elif [ -d "$in/AIM_SPORT/RaceStudio3/user" ]; then echo "$in/AIM_SPORT/RaceStudio3/user"
  fi
}

# _dir_has_session_file <dir> : true if <dir> contains at least one AiM session file — .xrk or
# .drk (recursive, case-insensitive). .drk is the older Race Studio data format (RS2-era); RS3's
# own importer reads it fine, so a dropped .drk is a session file worth routing into the data tree.
_dir_has_session_file() { [ -n "$(find "$1" -type f \( -iname '*.xrk' -o -iname '*.drk' \) -print -quit 2>/dev/null)" ]; }

# import_merge <source_dir> : public entry point for the Import droplet and the installer's
# optional "I have a folder" step. Merges an external AIM_SPORT/user (or its parent) into the
# live DATA_DIR using the SAME copy-if-absent engine — never overwrites existing user data.
# Accepts either a folder that IS the user tree (has cfgs/ or system/) or a parent containing
# AIM_SPORT/RaceStudio3/user.
import_merge() {
  local in="$1" usr
  usr="$(_find_user_tree "$in")"
  if [ -z "$usr" ]; then ui_error "couldn't find a RaceStudio3 user folder under: $in"; return 1; fi
  mkdir -p "$DATA_DIR"
  _merge_copy_if_absent "$usr" "$DATA_DIR" || { ui_error "import failed"; return 1; }
  local n; n="$(cd "$usr" && find . -type f | wc -l | tr -d ' ')"
  ui_say "Imported (merged, nothing overwritten): $n files from $usr"
}

# import_session_dir <dir> : import a folder of loose AiM session files (.xrk / .drk — no
# RaceStudio3 user tree). Copies every session file found (recursively, preserving relative
# paths) into DATA_DIR/data/<dir-name>/, never overwriting. Errors if the folder has no session
# files. .drk (the older Race Studio download format) is routed the same as .xrk. NOTE: RS3 does
# not scan the data folder — the staged files only appear once the user runs RS3's own Import
# (cogwheel → Import → Import Folder). The Import app guides them there.
import_session_dir() {
  local in="${1%/}" dest n=0 f rel rc=0
  dest="$DATA_DIR/data/$(basename "$in")"
  if ! _dir_has_session_file "$in"; then ui_error "no .xrk or .drk files found under: $in"; return 1; fi
  while IFS= read -r f; do
    rel="${f#"$in"/}"
    mkdir -p "$dest/$(dirname "$rel")" || { ui_error "import failed creating $(dirname "$rel")"; rc=1; break; }
    if [ ! -e "$dest/$rel" ]; then
      ditto "$f" "$dest/$rel" || { ui_error "import failed copying $rel"; rc=1; break; }
      n=$((n+1))
    fi
  done < <(find "$in" -type f \( -iname '*.xrk' -o -iname '*.drk' \))
  [ "$rc" -eq 0 ] || return 1
  if [ "$n" -eq 0 ]; then
    ui_say "No new session files to import — everything is already in the data folder."
    return 0
  fi
  ui_say "Imported $n session file(s) (nothing overwritten)."
  ui_import_dest "$dest"
}

# import_xrk_dir <dir> : back-compat wrapper for import_session_dir (historical name; a folder of
# loose .xrk sessions).
import_xrk_dir() { import_session_dir "$@"; }

# ---- configuration import (.zconf2 / .zconfig) ---------------------------------------------
# A configuration export is a zip whose top level holds one or more `cfg_<timestamp>` folders (the
# `.aimcfg` plus its `devices/` tree) and, optionally, a `to_copy_in_app_root_folder/user/…`
# payload of shared resources — overlay icons, masks and the like.
#
# Unlike a session, a configuration really can be imported without RaceStudio 3's own Import step.
# RS3's database (`database/data.xrd`) has no configurations table: it lists whatever
# `cfgs/<cfg_*>` folders it finds on disk. So copying the folder in IS the import; the
# configuration shows up the next time RS3 starts.

# _find_config_dirs <dir> : print the configuration folders inside an unpacked archive, one per
# line — a top-level folder holding at least one `.aimcfg`.
_find_config_dirs() {
  local d
  for d in "$1"/*/; do
    [ -d "$d" ] || continue
    # A .zconf2 is an untrusted zip and `ditto -x` recreates symlink entries verbatim, so a config
    # folder that is really a link would be copied into the live cfgs/ still pointing outside the
    # data tree. Only a real directory is a configuration. (ditto DOES flatten `../` traversal
    # entries into the destination, verified 2026-08-26, so only links need rejecting here.)
    [ ! -L "${d%/}" ] || continue
    [ -n "$(find "$d" -maxdepth 1 -type f -iname '*.aimcfg' -print -quit 2>/dev/null)" ] || continue
    printf '%s\n' "${d%/}"
  done
}

# _cfg_label <cfg_dir> : the name RaceStudio 3 shows for a configuration — its `.aimcfg` filename
# without the extension. The folder name is only a timestamp, so it is useless in a dialog.
_cfg_label() {
  local f
  f="$(find "$1" -maxdepth 1 -type f -iname '*.aimcfg' -print -quit 2>/dev/null)"
  if [ -z "$f" ]; then basename "$1"; return 0; fi
  f="$(basename "$f")"
  printf '%s' "${f%.*}"
}

# _cfg_already_imported <cfgs_dir> <base> <src_dir> : true when <src_dir> is identical to a
# configuration already there — either under the archive's own name or one of its `_NN` siblings.
# Dropping the same file twice should say so rather than stack another copy; RS3's own importer
# never checks, which is how a data folder ends up with a dozen identical `cfg_…_NN` twins.
_cfg_already_imported() {
  local root="$1" base="$2" src="$3" d
  for d in "$root/$base" "$root/$base"_[0-9][0-9]; do
    [ -d "$d" ] || continue
    diff -rq "$src" "$d" >/dev/null 2>&1 && return 0
  done
  return 1
}

# _cfg_free_name <cfgs_dir> <base> : echo a free folder name under <cfgs_dir>, using RaceStudio 3's
# own collision convention (`<base>_01` … `<base>_99`). Echoes nothing and returns 1 if all are
# taken — better a clear error than silently overwriting somebody's configuration.
_cfg_free_name() {
  local root="$1" base="$2" i=1 n
  # `-e` alone would call a DANGLING symlink free, and the caller's failure branch would then
  # rm -rf the user's link on its way out. A name is taken if anything is there at all.
  if [ ! -e "$root/$base" ] && [ ! -L "$root/$base" ]; then printf '%s' "$base"; return 0; fi
  while [ "$i" -le 99 ]; do
    n="$(printf '%s_%02d' "$base" "$i")"
    if [ ! -e "$root/$n" ] && [ ! -L "$root/$n" ]; then printf '%s' "$n"; return 0; fi
    i=$((i+1))
  done
  return 1
}

# import_config_archive <file> : import an AiM configuration export into DATA_DIR/cfgs/. Nothing is
# overwritten — a name that is taken gets the `_NN` suffix, and the shared-resource payload is
# merged copy-if-absent by the same engine as import_merge.
import_config_archive() {
  local zip="$1" tmp cfgs dirs d base name payload n=0 found=0 failed=0 res=0
  [ -f "$zip" ] || { ui_error "Import: file not found: $zip"; return 1; }
  cfgs="$DATA_DIR/cfgs"
  mkdir -p "$cfgs" || { ui_error "Import: couldn't create $cfgs"; return 1; }
  tmp="$(mktemp -d "${TMPDIR:-/tmp}/rs3cfg.XXXXXX")" || { ui_error "Import: couldn't make a temp folder"; return 1; }

  ui_say "Unpacking configuration…"
  if ! ditto -x -k "$zip" "$tmp" 2>/dev/null && ! unzip -q "$zip" -d "$tmp" 2>/dev/null; then
    rm -rf "$tmp"
    ui_error "Import: '$(basename "$zip")' is not a readable AiM configuration export."
    return 1
  fi

  dirs="$(_find_config_dirs "$tmp")"
  if [ -z "$dirs" ]; then
    rm -rf "$tmp"
    ui_error "Import: '$(basename "$zip")' has no configuration in it (no .aimcfg found)."
    return 1
  fi

  while IFS= read -r d; do
    [ -n "$d" ] || continue
    found=$((found+1))
    base="$(basename "$d")"
    if _cfg_already_imported "$cfgs" "$base" "$d"; then
      ui_import_config_dup "$(_cfg_label "$d")"
      continue
    fi
    # The top-level `-L` check in _find_config_dirs is not enough: ditto preserves symlinks INSIDE
    # the folder too, so `cfg_x/devices -> /` would plant a link to the whole Mac under cfgs/.
    # RS3 walks that tree with no depth cap and hangs on the resulting cycle — the same failure as
    # issue #32's `z:` drive. A configuration RS3 exported never contains one.
    if [ -n "$(find "$d" -type l -print -quit 2>/dev/null)" ]; then
      rm -rf "$tmp"
      ui_error "Import: '$base' contains symbolic links, which a RaceStudio 3 configuration never does. Refusing to copy it into your data folder."
      return 1
    fi
    name="$(_cfg_free_name "$cfgs" "$base")" || {
      rm -rf "$tmp"; ui_error "Import: $cfgs already holds 100 copies of $base"; return 1
    }
    # One bad copy in a multi-configuration archive must not report the whole import as failed —
    # the ones already in cfgs/ are really there, and the applet discards stdout on a non-zero exit.
    if ditto "$d" "$cfgs/$name"; then
      n=$((n+1))
      ui_import_config "$(_cfg_label "$d")"
    else
      # A half-written config directory in cfgs/ is worse than none: RS3 lists it and the next
      # attempt sees the name as taken. _cfg_free_name guaranteed this path did not exist before
      # the copy, so removing it can only take back what this run just made.
      rm -rf "$cfgs/$name"
      failed=$((failed+1))
      ui_warn "couldn't copy configuration $base"
    fi
  done < <(printf '%s\n' "$dirs")

  # Shared resources the configuration references (overlay icons and masks) live beside the cfg
  # folders and belong at the root of the data folder. Merge EVERY such payload — an archive can
  # carry more than one, and stopping at the first drops icons the config points at. Copy-if-absent
  # throughout: a user's own file wins, and _merge_copy_if_absent skips symlink entries because it
  # only walks `-type f` and `-type d`.
  while IFS= read -r payload; do
    [ -n "$payload" ] || continue
    _merge_copy_if_absent "$payload" "$DATA_DIR" || {
      rm -rf "$tmp"; ui_error "Import: failed copying the configuration's shared resources"; return 1
    }
    # Count what actually landed. A configuration can be a duplicate while its icons and masks are
    # new, and saying "nothing new" then would be untrue.
    res=$((res + ${#_MERGED_COPIED[@]}))
  done < <(find "$tmp" -mindepth 2 -maxdepth 2 -type d -name user -path '*to_copy_in_app_root*' 2>/dev/null)
  [ "$res" -eq 0 ] || ui_import_extras "$res"
  rm -rf "$tmp"

  if [ "$n" -gt 0 ]; then
    ui_say "Imported $n configuration(s) of $found."
    [ "$failed" -eq 0 ] || ui_warn "$failed configuration(s) in the archive could not be copied"
    return 0
  fi
  if [ "$failed" -gt 0 ]; then
    ui_error "Import: none of the $found configuration(s) in '$(basename "$zip")' could be copied"
    return 1
  fi
  if [ "$res" -gt 0 ]; then
    ui_say "That configuration was already in RaceStudio 3; added $res new shared resource file(s)."
  else
    ui_say "Nothing new — that configuration is already in RaceStudio 3."
  fi
  return 0
}
