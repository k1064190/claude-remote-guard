#!/usr/bin/env bash
# test-guard-remote-toggle.sh — behavior tests for scripts/guard-remote-toggle.sh
# (duration / persist arguments) and scripts/guard-remote-session-reset.sh
# (SessionStart cleanup). Runs under an isolated HOME.
set -u

here=$(cd "$(dirname "$0")" && pwd)
TOGGLE="$here/../scripts/guard-remote-toggle.sh"
RESET="$here/../scripts/guard-remote-session-reset.sh"

TEST_HOME=$(mktemp -d)
trap 'rm -rf "$TEST_HOME"' EXIT
flag_dir="$TEST_HOME/.claude/remote-guard"
read_flag="$flag_dir/bypass-read"
write_flag="$flag_dir/bypass-write"

pass=0
fail=0

toggle() { HOME="$TEST_HOME" bash "$TOGGLE" "$@"; }
reset_hook() { HOME="$TEST_HOME" bash "$RESET"; }

# ok <description> <command...> — count pass/fail of an assertion command.
ok() {
  local desc="$1"; shift
  if "$@"; then
    pass=$((pass + 1))
  else
    fail=$((fail + 1))
    printf 'FAIL  %s\n' "$desc"
  fi
}

flag_is() { # flag_is <path> <empty|persist|epoch-future|epoch-past|absent>
  local f="$1" want="$2" v
  case "$want" in
    absent) [ ! -f "$f" ]; return ;;
  esac
  [ -f "$f" ] || return 1
  v=$(cat "$f")
  case "$want" in
    empty)        [ -z "$v" ] ;;
    persist)      [ "$v" = persist ] ;;
    epoch-future) case "$v" in ''|*[!0-9]*) return 1;; esac; [ "$v" -gt "$(date +%s)" ] ;;
    epoch-past)   case "$v" in ''|*[!0-9]*) return 1;; esac; [ "$v" -le "$(date +%s)" ] ;;
  esac
}

# --- Toggle: no duration keeps the session-scoped flip behavior --------------------
toggle write >/dev/null
ok 'write flip on -> empty session flag' flag_is "$write_flag" empty
toggle write >/dev/null
ok 'write flip off -> flag removed' flag_is "$write_flag" absent

# --- Toggle: duration writes an expiry epoch ---------------------------------------
toggle write 30m >/dev/null
ok 'write 30m -> future epoch' flag_is "$write_flag" epoch-future
exp1=$(cat "$write_flag")
toggle write 2h >/dev/null
exp2=$(cat "$write_flag")
ok 'duration re-run refreshes (sets, not flips)' test "$exp2" -gt "$exp1"
toggle off >/dev/null
ok 'off clears TTL flag' flag_is "$write_flag" absent

toggle read 45s >/dev/null
ok 'read 45s -> future epoch' flag_is "$read_flag" epoch-future
toggle all 1h >/dev/null
ok 'all 1h -> read epoch' flag_is "$read_flag" epoch-future
ok 'all 1h -> write epoch' flag_is "$write_flag" epoch-future
toggle off >/dev/null

# Bare number = minutes.
toggle write 10 >/dev/null
ok 'bare number treated as minutes' flag_is "$write_flag" epoch-future
toggle off >/dev/null

# --- Toggle: persist ----------------------------------------------------------------
toggle write persist >/dev/null
ok 'write persist -> persist flag' flag_is "$write_flag" persist
toggle off >/dev/null
ok 'off clears persist flag' flag_is "$write_flag" absent

# --- Toggle: leading zeros are base 10, not octal ------------------------------------
toggle write 010m >/dev/null
exp=$(cat "$write_flag")
ok '010m parses as 10 minutes (base 10)' test "$exp" -ge "$(( $(date +%s) + 590 ))"
toggle write 08m >/dev/null               # would be an octal arithmetic error
ok '08m accepted as 8 minutes' flag_is "$write_flag" epoch-future
toggle off >/dev/null

# --- Toggle: flipping a stale (expired/garbage) flag turns the bypass ON -------------
printf '%s' "$(( $(date +%s) - 10 ))" > "$write_flag"
toggle write >/dev/null
ok 'flip on expired flag -> session bypass ON' flag_is "$write_flag" empty
toggle off >/dev/null
printf 'garbage!' > "$read_flag"
toggle all >/dev/null                     # stale read flag counts as OFF -> both turn ON
ok 'all with stale flag -> read session ON' flag_is "$read_flag" empty
ok 'all with stale flag -> write session ON' flag_is "$write_flag" empty
toggle off >/dev/null

# --- Toggle: invalid / over-cap durations are rejected ------------------------------
out=$(toggle write banana 2>&1)
ok 'invalid duration rejected' flag_is "$write_flag" absent
printf '%s' "$out" | grep -qi 'usage\|invalid' \
  && pass=$((pass + 1)) || { fail=$((fail + 1)); echo 'FAIL  invalid duration should print usage'; }
out=$(toggle write 25h 2>&1)
ok 'duration above 24h cap rejected' flag_is "$write_flag" absent
out=$(toggle write 99999999999999999999999999999999999999s 2>&1)
ok 'overflow-sized duration rejected' flag_is "$write_flag" absent

# --- Toggle: status reports remaining time ------------------------------------------
toggle write 30m >/dev/null
out=$(toggle status)
printf '%s' "$out" | grep -q 'ON' \
  && pass=$((pass + 1)) || { fail=$((fail + 1)); echo 'FAIL  status should show ON for TTL flag'; }
toggle off >/dev/null

# --- SessionStart reset: session flags cleared, TTL/persist kept --------------------
mkdir -p "$flag_dir"
: > "$read_flag"                                   # session-scoped
printf '%s' "$(( $(date +%s) + 3600 ))" > "$write_flag"  # unexpired TTL
reset_hook
ok 'reset clears session-scoped flag' flag_is "$read_flag" absent
ok 'reset keeps unexpired TTL flag' flag_is "$write_flag" epoch-future

printf '%s' "$(( $(date +%s) - 10 ))" > "$write_flag"    # expired TTL
reset_hook
ok 'reset clears expired TTL flag' flag_is "$write_flag" absent

printf 'persist' > "$write_flag"
reset_hook
ok 'reset keeps persist flag' flag_is "$write_flag" persist
printf 'garbage!' > "$write_flag"
reset_hook
ok 'reset clears unknown flag content' flag_is "$write_flag" absent

printf '\n%d passed, %d failed\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
