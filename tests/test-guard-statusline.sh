#!/usr/bin/env bash
# test-guard-statusline.sh — behavior tests for the status-line composition:
#   scripts/statusline-guard.sh       (render-time wrapper)
#   scripts/guard-statusline-setup.sh (install / uninstall / status)
# Runs under an isolated HOME so the real settings.json and bypass flags never
# leak in. Mirrors the harness style of the other test-*.sh files.
set -u

here=$(cd "$(dirname "$0")" && pwd)
WRAP="$here/../scripts/statusline-guard.sh"
SETUP="$here/../scripts/guard-statusline-setup.sh"

TEST_HOME=$(mktemp -d)
trap 'rm -rf "$TEST_HOME"' EXIT
guard_dir="$TEST_HOME/.claude/remote-guard"
settings="$TEST_HOME/.claude/settings.json"
wrapper_dst="$guard_dir/statusline.sh"
mkdir -p "$TEST_HOME/.claude"

pass=0
fail=0

# ok <description> <command...> — count pass/fail of an assertion command.
ok() {
  local desc="$1"; shift
  if "$@"; then pass=$((pass + 1)); else fail=$((fail + 1)); printf 'FAIL  %s\n' "$desc"; fi
}

# eq <want> <got> — string equality assertion helper.
eq() { [ "$1" = "$2" ] || { printf '  want=[%s] got=[%s]\n' "$1" "$2" >&2; return 1; }; }

wrap()  { printf '%s' "${2:-}" | HOME="$TEST_HOME" bash "$WRAP"; }   # wrap <_> <stdin>
setup() { HOME="$TEST_HOME" bash "$SETUP" "$@"; }
scmd()  { jq -r '.statusLine.command // ""' "$settings" 2>/dev/null; }
reset_state() { rm -rf "$guard_dir"; rm -f "$settings"; mkdir -p "$guard_dir"; }

# ---- wrapper: guard indicator only (no inner status line) -------------------
reset_state
ok 'armed when no bypass flags'          eq '🔒 guard: armed'      "$(wrap _ '')"
: > "$guard_dir/bypass-write"
ok 'write bypass shown'                  eq '🔓 guard: W bypass'   "$(wrap _ '')"
: > "$guard_dir/bypass-read"
ok 'read+write bypass shown'             eq '🔓 guard: RW bypass'  "$(wrap _ '')"
rm -f "$guard_dir/bypass-write"
ok 'read-only bypass shown'              eq '🔓 guard: R bypass'   "$(wrap _ '')"

# ---- wrapper: composes on top of an inner status line -----------------------
reset_state
printf 'echo INNER' > "$guard_dir/statusline-inner"
ok 'inner output precedes guard line'    eq $'INNER\n🔒 guard: armed' "$(wrap _ '')"

# inner receives the status-line stdin unchanged
printf 'cat' > "$guard_dir/statusline-inner"
ok 'stdin passed through to inner'       eq $'{"x":1}\n🔒 guard: armed' "$(wrap _ '{"x":1}')"

# empty inner file -> guard line only, no leading blank line
reset_state
: > "$guard_dir/statusline-inner"
ok 'empty inner -> guard only'           eq '🔒 guard: armed'      "$(wrap _ '')"

# ---- setup: install wraps the existing status line --------------------------
reset_state
printf '{"statusLine":{"type":"command","command":"echo BASE"},"other":"keep"}\n' > "$settings"
setup install >/dev/null
ok 'install repoints statusLine to wrapper'  eq "bash \"$wrapper_dst\"" "$(scmd)"
ok 'install preserves other settings keys'   eq 'keep' "$(jq -r '.other' "$settings")"
ok 'install records inner command'           eq 'echo BASE' "$(cat "$guard_dir/statusline-inner")"
ok 'install copies executable wrapper'       test -x "$wrapper_dst"
ok 'installed wrapper composes base + guard' eq $'BASE\n🔒 guard: armed' "$(wrap _ '')"

# idempotent: re-running install must not wrap the wrapper (inner unchanged)
setup install >/dev/null
ok 'install is idempotent (inner intact)'    eq 'echo BASE' "$(cat "$guard_dir/statusline-inner")"

# uninstall restores the exact original statusLine object
setup uninstall >/dev/null
ok 'uninstall restores inner command'        eq 'echo BASE' "$(scmd)"
ok 'uninstall restores statusLine type'      eq 'command' "$(jq -r '.statusLine.type' "$settings")"
ok 'uninstall keeps other settings keys'     eq 'keep' "$(jq -r '.other' "$settings")"
ok 'uninstall clears wrapper copy'           test ! -e "$wrapper_dst"

# ---- setup: install with no prior status line -------------------------------
reset_state
printf '{"other":"x"}\n' > "$settings"
setup install >/dev/null
ok 'install w/o prior: empty inner'          eq '' "$(cat "$guard_dir/statusline-inner")"
ok 'install w/o prior: wrapper is guard only' eq '🔒 guard: armed' "$(wrap _ '')"
setup uninstall >/dev/null
ok 'uninstall w/o prior removes statusLine'   eq 'null' "$(jq -r '.statusLine // "null"' "$settings")"
ok 'uninstall w/o prior keeps other keys'     eq 'x' "$(jq -r '.other' "$settings")"

# ---- setup: uninstall when not installed is a no-op -------------------------
reset_state
printf '{"statusLine":{"type":"command","command":"echo MINE"}}\n' > "$settings"
setup uninstall >/dev/null
ok 'uninstall no-op leaves foreign statusLine' eq 'echo MINE' "$(scmd)"

# ---- setup: malformed settings.json is refused, not clobbered ---------------
reset_state
printf '{ not valid json' > "$settings"
if setup install >/dev/null 2>&1; then ok 'install rejects malformed settings' false
else ok 'install rejects malformed settings' true; fi
ok 'malformed settings left untouched'       eq '{ not valid json' "$(cat "$settings")"

# ---- install/execute survives spaces in $HOME (and thus the wrapper path) ----
sp_home=$(mktemp -d "${TMPDIR:-/tmp}/guard sp.XXXXXX")
sp_settings="$sp_home/.claude/settings.json"
sp_wrap="$sp_home/.claude/remote-guard/statusline.sh"
mkdir -p "$sp_home/.claude"
printf '{"statusLine":{"type":"command","command":"echo BASE"}}\n' > "$sp_settings"
HOME="$sp_home" bash "$SETUP" install >/dev/null
ok 'spaced-path install quotes wrapper path'  eq "bash \"$sp_wrap\"" "$(jq -r '.statusLine.command' "$sp_settings")"
# the stored command string, run through a shell, must not word-split on the space
sp_out="$(printf '{}' | HOME="$sp_home" bash -c "$(jq -r '.statusLine.command' "$sp_settings")")"
ok 'spaced-path stored command executes'      eq $'BASE\n🔒 guard: armed' "$sp_out"
rm -rf "$sp_home"

printf '\n%d passed, %d failed\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
