#!/usr/bin/env bash
# guard-remote-toggle.sh [read|write|all|off|status] [duration|persist] — remote-guard plugin.
# Toggles session-scoped bypass flags read by guard-remote-ops.sh:
#   read  flag -> read-only remote/cloud queries (list/describe/get/show/logs/plan...)
#                 run WITHOUT a prompt.
#   write flag -> write/dangerous commands (create/delete/update/apply/exec/ssh/scp/
#                 bq query...) run WITHOUT a prompt.
# With no second argument the flag is session-scoped (flipped on/off; a SessionStart
# hook removes it on each new session). A duration (30m / 2h / 45s / bare number =
# minutes, max 24h) instead SETS the flag until that time — it survives restarts and
# the guard re-arms automatically when it expires. `persist` keeps the flag until an
# explicit /unguard off. Flag file contents encode the mode: empty = session,
# digits = expiry epoch, "persist" = permanent.
# No argument just reports the current state.
set -euo pipefail

dir="$HOME/.claude/remote-guard"
read_flag="$dir/bypass-read"
write_flag="$dir/bypass-write"
mkdir -p "$dir"
now=$(date +%s)

# The /unguard command hands all arguments over as one word ("write 30m"), so
# re-split on whitespace before parsing.
# shellcheck disable=SC2086
set -- ${*:-status}
action="${1:-status}"
dur="${2:-}"

usage() {
  echo "Usage: /unguard [read|write|all|off|status] [30m|2h|45s|persist]"
  echo "  duration: bypass survives restarts until it expires (max 24h)"
  echo "  persist : bypass survives restarts until /unguard off"
}

# parse_ttl <dur> -> seconds on stdout; fails on non-numeric input.
# Suffixes: h(ours), m(inutes), s(econds); a bare number means minutes.
parse_ttl() {
  local d="$1" n unit=m
  case "$d" in
    *[hms]) unit="${d: -1}"; n="${d%?}" ;;
    *)      n="$d" ;;
  esac
  case "$n" in ''|*[!0-9]*) return 1 ;; esac
  case "$unit" in
    h) echo $((n * 3600)) ;;
    m) echo $((n * 60)) ;;
    s) echo "$n" ;;
  esac
}

# Resolve the requested mode: session (default flip), ttl, or persist.
mode=session
ttl=
if [ -n "$dur" ]; then
  if [ "$dur" = persist ]; then
    mode=persist
  elif ttl=$(parse_ttl "$dur"); then
    if [ "$ttl" -gt 86400 ]; then
      echo "Invalid duration '$dur' — max is 24h."
      usage
      exit 0
    fi
    mode=ttl
  else
    echo "Invalid duration '$dur'."
    usage
    exit 0
  fi
fi

# state <flag> -> OFF / ON (this session) / ON (persist) / ON (<remaining> left).
# An expired or unrecognized flag reads as OFF and is cleaned up.
state() {
  local v rem
  [ -f "$1" ] || { echo OFF; return; }
  v=$(cat "$1" 2>/dev/null) || { echo OFF; return; }
  case "$v" in
    '')      echo "ON (this session)" ;;
    persist) echo "ON (persist)" ;;
    *[!0-9]*) rm -f "$1"; echo OFF ;;
    *)
      if [ "$now" -lt "$v" ]; then
        rem=$((v - now))
        if   [ "$rem" -ge 3600 ]; then echo "ON ($((rem / 3600))h$(((rem % 3600) / 60))m left)"
        elif [ "$rem" -ge 60 ];   then echo "ON ($((rem / 60))m left)"
        else                           echo "ON (${rem}s left)"
        fi
      else
        rm -f "$1"; echo OFF
      fi ;;
  esac
}

# enable <flag> — write the flag in the requested mode (ttl / persist).
enable() {
  case "$mode" in
    ttl)     printf '%s' "$((now + ttl))" > "$1" ;;
    persist) printf 'persist' > "$1" ;;
  esac
}

flip() { if [ -f "$1" ]; then rm -f "$1"; else : > "$1"; fi; }

# Session mode keeps the original flip semantics; a duration/persist argument
# always SETS (re-running refreshes the expiry instead of turning it off).
apply() { if [ "$mode" = session ]; then flip "$1"; else enable "$1"; fi; }

case "$action" in
  read)   apply "$read_flag" ;;
  write)  apply "$write_flag" ;;
  all)    if [ "$mode" = session ]; then
            if [ -f "$read_flag" ] || [ -f "$write_flag" ]; then
              rm -f "$read_flag" "$write_flag"          # any on -> turn both off
            else
              : > "$read_flag"; : > "$write_flag"       # both off -> turn both on
            fi
          else
            enable "$read_flag"; enable "$write_flag"
          fi ;;
  off|reset) rm -f "$read_flag" "$write_flag" ;;
  status) ;;
  *) usage; exit 0 ;;
esac

echo "Remote/cloud guard bypass — read(조회): $(state "$read_flag")  |  write(변경·삭제·ssh): $(state "$write_flag")"
echo "  read ON  = list/describe/get/show/logs/plan ... run without a prompt"
echo "  write ON = create/delete/update/apply/exec/ssh/scp/bq query ... run without a prompt"
echo "  session bypass resets on restart; timed (e.g. /unguard write 30m) survives restarts"
echo "  until it expires; persist survives until /unguard off."
