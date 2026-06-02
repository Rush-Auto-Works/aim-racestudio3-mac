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
    if [ ! -e "$dst/$rel" ]; then
      tmp="$dst/$rel.tmp.$$"
      ditto "$src/$rel" "$tmp" && mv -f "$tmp" "$dst/$rel" || { rm -f "$tmp"; return 1; }
      _MERGED_COPIED+=("$rel")
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

# import_merge <source_dir> : public entry point for the Import droplet and the installer's
# optional "I have a folder" step. Merges an external AIM_SPORT/user (or its parent) into the
# live DATA_DIR using the SAME copy-if-absent engine — never overwrites existing user data.
# Accepts either a folder that IS the user tree (has cfgs/ or system/) or a parent containing
# AIM_SPORT/RaceStudio3/user.
import_merge() {
  local in="$1" usr=""
  if [ -d "$in/cfgs" ] || [ -d "$in/system" ] || [ -d "$in/profiles" ]; then
    usr="$in"
  elif [ -d "$in/RaceStudio3/user" ]; then
    usr="$in/RaceStudio3/user"
  elif [ -d "$in/AIM_SPORT/RaceStudio3/user" ]; then
    usr="$in/AIM_SPORT/RaceStudio3/user"
  fi
  if [ -z "$usr" ]; then ui_error "couldn't find a RaceStudio3 user folder under: $in"; return 1; fi
  mkdir -p "$DATA_DIR"
  _merge_copy_if_absent "$usr" "$DATA_DIR" || { ui_error "import failed"; return 1; }
  local n; n="$(cd "$usr" && find . -type f | wc -l | tr -d ' ')"
  ui_say "Imported (merged, nothing overwritten): $n files from $usr"
}
