# lib/ui.sh — user-facing output + the applet<->core interaction contract.
#
# UI_MODE selects behaviour:
#   applet  : invoked by the AppleScript app. Core phases are NON-INTERACTIVE.
#             Status/progress are printed as machine-readable lines the applet parses;
#             a needed decision prints "NEEDS_CHOICE <key>" / "NEEDS_CONFIRM <key>" and
#             exits SIG_NEEDS so the applet can render a native dialog, persist the answer
#             to config.env, and re-invoke the phase. The core NEVER spawns its own dialog.
#   cli     : standalone (`installer-core.sh run` in a Terminal). ui_ask uses osascript when
#             a display is available, else `read`; answers are persisted to config.env here.
#   dryrun  : no interaction, no osascript; uses the default for every choice and plain-echoes.
#
# Decisions persist in $CONFIG_ENV (state/config.env) as KEY="value" lines so every separate
# per-phase process re-sources the same answers (round-3 resolution 12).

SIG_NEEDS=10   # exit code meaning "applet must collect a decision and re-invoke"

: "${UI_MODE:=cli}"

_is_tty() { [ -t 1 ]; }

ui_say() {  # informational line
  case "$UI_MODE" in
    applet) printf 'STATUS: %s\n' "$1" ;;
    *)      printf '==> %s\n' "$1" ;;
  esac
}

ui_progress() {  # <step> <total> <description>
  case "$UI_MODE" in
    applet) printf 'PROGRESS: %s %s %s\n' "$1" "$2" "$3" ;;
    *)      printf '[%s/%s] %s\n' "$1" "$2" "$3" ;;
  esac
}

ui_warn() {
  case "$UI_MODE" in
    applet) printf 'WARN: %s\n' "$1" ;;
    *)      printf 'WARNING: %s\n' "$1" >&2 ;;
  esac
}

# ui_error just records the message; the EXIT trap decides how to surface it (dialog in cli,
# ERROR line for the applet to render).
ui_error() {
  LAST_ERROR="$1"
  case "$UI_MODE" in
    applet) printf 'ERROR: %s\n' "$1" ;;
    *)      printf 'ERROR: %s\n' "$1" >&2 ;;
  esac
}

# Persist a resolved decision so later phases (separate processes) see it.
ui_persist() {  # <key> <value>
  local key="$1" val="$2" tmp
  [ -n "${CONFIG_ENV:-}" ] || return 0
  mkdir -p "$(dirname "$CONFIG_ENV")"
  tmp="$CONFIG_ENV.tmp.$$"
  if [ -f "$CONFIG_ENV" ]; then grep -v "^${key}=" "$CONFIG_ENV" > "$tmp" 2>/dev/null || true; else : > "$tmp"; fi
  printf '%s=%q\n' "$key" "$val" >> "$tmp"
  mv -f "$tmp" "$CONFIG_ENV"
}

# Read a previously-persisted decision into the named variable. Returns 0 if found.
ui_recall() {  # <key>  -> echoes value, returns 0 if present
  [ -n "${CONFIG_ENV:-}" ] && [ -f "$CONFIG_ENV" ] || return 1
  local line; line="$(grep "^${1}=" "$CONFIG_ENV" 2>/dev/null | tail -1)" || return 1
  [ -n "$line" ] || return 1
  # value is %q-quoted; eval just the RHS safely into a local
  local v; eval "v=${line#*=}"
  printf '%s' "$v"
}

# ui_choice <key> <default> <prompt> <opt1> [opt2 ...]
# Returns the chosen option on stdout via the CHOICE_RESULT variable.
ui_choice() {
  local key="$1" def="$2" prompt="$3"; shift 3
  local prior; if prior="$(ui_recall "$key")"; then CHOICE_RESULT="$prior"; return 0; fi
  case "$UI_MODE" in
    dryrun) CHOICE_RESULT="$def"; return 0 ;;
    applet) printf 'NEEDS_CHOICE: %s\n' "$key"; exit "$SIG_NEEDS" ;;
    cli)
      local ans
      if _is_tty; then
        printf '%s\n' "$prompt"
        local i=1; for o in "$@"; do printf '  %d) %s\n' "$i" "$o"; i=$((i+1)); done
        printf 'choose [%s]: ' "$def"; read -r ans || ans=""
        if [ -n "$ans" ] && [ "$ans" -ge 1 ] 2>/dev/null && [ "$ans" -le $# ]; then
          ans="$(eval "echo \${$ans}")"
        else ans="$def"; fi
      else ans="$def"; fi
      ui_persist "$key" "$ans"; CHOICE_RESULT="$ans"; return 0 ;;
  esac
}

# ui_confirm <key> <default yes|no> <prompt> -> returns 0 for yes, 1 for no
ui_confirm() {
  local key="$1" def="$2" prompt="$3"
  [ "${RS3_ASSUME_YES:-0}" = 1 ] && return 0    # non-interactive opt-in (CI/e2e)
  local prior; if prior="$(ui_recall "$key")"; then [ "$prior" = yes ]; return; fi
  case "$UI_MODE" in
    dryrun) [ "$def" = yes ] ;;
    applet) printf 'NEEDS_CONFIRM: %s\n' "$key"; exit "$SIG_NEEDS" ;;
    cli)
      local ans
      if _is_tty; then printf '%s [%s]: ' "$prompt" "$def"; read -r ans || ans=""; else ans=""; fi
      [ -z "$ans" ] && ans="$def"
      case "$ans" in y|yes|Y) ans=yes;; *) ans=no;; esac
      ui_persist "$key" "$ans"; [ "$ans" = yes ] ;;
  esac
}
