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
perms() { stat -c '%a' "$1" 2>/dev/null || stat -f '%Lp' "$1" 2>/dev/null; }
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

# flag CONTENTS decide the state (mirrors the guard), not mere file existence
reset_state
printf '%s' "$(( $(date +%s) - 60 ))"   > "$guard_dir/bypass-write"   # expired epoch
ok 'expired timed bypass reads as armed' eq '🔒 guard: armed'      "$(wrap _ '')"
printf '%s' "$(( $(date +%s) + 3600 ))" > "$guard_dir/bypass-write"   # future epoch
ok 'unexpired timed bypass shown'        eq '🔓 guard: W bypass'   "$(wrap _ '')"
printf 'persist'                        > "$guard_dir/bypass-read"    # permanent
ok 'persist bypass shown'                eq '🔓 guard: RW bypass'  "$(wrap _ '')"

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
printf '{"statusLine":{"type":"command","command":"echo BASE","padding":0},"other":"keep"}\n' > "$settings"
setup install >/dev/null
ok 'install repoints statusLine to wrapper'  eq "bash $(printf '%q' "$wrapper_dst")" "$(scmd)"
ok 'install preserves other settings keys'   eq 'keep' "$(jq -r '.other' "$settings")"
ok 'install preserves sibling statusLine key' eq '0' "$(jq -r '.statusLine.padding' "$settings")"
ok 'install records inner command'           eq 'echo BASE' "$(cat "$guard_dir/statusline-inner")"
ok 'inner command backup is owner-only'      eq '600' "$(perms "$guard_dir/statusline-inner")"
ok 'inner object backup is owner-only'       eq '600' "$(perms "$guard_dir/statusline-inner.json")"
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
ok 'spaced-path install quotes wrapper path'  eq "bash $(printf '%q' "$sp_wrap")" "$(jq -r '.statusLine.command' "$sp_settings")"
# the stored command string, run through a shell, must not word-split on the space
sp_out="$(printf '{}' | HOME="$sp_home" bash -c "$(jq -r '.statusLine.command' "$sp_settings")")"
ok 'spaced-path stored command executes'      eq $'BASE\n🔒 guard: armed' "$sp_out"
rm -rf "$sp_home"

# ---- install/execute survives shell metacharacters ($) in the path -----------
mc_home=$(mktemp -d "${TMPDIR:-/tmp}/guard\$meta.XXXXXX")   # literal $ in dir name
mkdir -p "$mc_home/.claude"
printf '{"statusLine":{"type":"command","command":"echo MC"}}\n' > "$mc_home/.claude/settings.json"
HOME="$mc_home" bash "$SETUP" install >/dev/null
# the stored command must not re-expand $meta when a shell runs it
mc_out="$(printf '{}' | HOME="$mc_home" bash -c "$(jq -r '.statusLine.command' "$mc_home/.claude/settings.json")")"
ok 'metachar-path stored command executes'    eq $'MC\n🔒 guard: armed' "$mc_out"
rm -rf "$mc_home"

# ---- wrapper passes stdin to inner intact, including the trailing newline -----
reset_state
printf 'cat > "$HOME/.claude/seen"' > "$guard_dir/statusline-inner"
printf '{"a":1}\n' | HOME="$TEST_HOME" bash "$WRAP" >/dev/null   # 8 bytes in
ok 'inner stdin keeps trailing newline' \
   eq '8' "$(wc -c < "$TEST_HOME/.claude/seen" | tr -d ' ')"

# ---- settings.json managed as a symlink (stow/yadm) stays a symlink ----------
reset_state
real="$TEST_HOME/.claude/settings.real.json"
printf '{"statusLine":{"type":"command","command":"echo BASE"},"k":"v"}\n' > "$real"
ln -sf "$real" "$settings"
setup install >/dev/null
ok 'install keeps settings a symlink'         test -L "$settings"
ok 'install writes through to real target'     eq "bash $(printf '%q' "$wrapper_dst")" "$(jq -r '.statusLine.command' "$real")"
ok 'install through symlink preserves keys'    eq 'v' "$(jq -r '.k' "$real")"
setup uninstall >/dev/null
ok 'uninstall keeps settings a symlink'        test -L "$settings"
ok 'uninstall restores real target'            eq 'echo BASE' "$(jq -r '.statusLine.command' "$real")"

# ---- install warns when a project/local statusLine would shadow it ----------
reset_state
proj=$(mktemp -d)
mkdir -p "$proj/.claude"
printf '{"statusLine":{"type":"command","command":"echo PROJ"}}\n' > "$proj/.claude/settings.json"
sh_out="$(cd "$proj" && HOME="$TEST_HOME" bash "$SETUP" install 2>&1)"
ok 'warns on project statusLine shadow' \
   sh -c "printf '%s' \"\$1\" | grep -q 'overrides the user-level one'" _ "$sh_out"
# a project WITHOUT a statusLine must not warn
rm -f "$proj/.claude/settings.json"
printf '{"other":"x"}\n' > "$proj/.claude/settings.json"
reset_state
sh_out="$(cd "$proj" && HOME="$TEST_HOME" bash "$SETUP" install 2>&1)"
ok 'no warning without project statusLine' \
   sh -c "! printf '%s' \"\$1\" | grep -q 'overrides the user-level one'" _ "$sh_out"
rm -rf "$proj"

# install warns from a SUBDIRECTORY of a project whose root defines a statusLine
reset_state
proj=$(mktemp -d)
mkdir -p "$proj/.claude" "$proj/sub/deep"
printf '{"statusLine":{"type":"command","command":"echo P"}}\n' > "$proj/.claude/settings.json"
sh_out="$(cd "$proj/sub/deep" && HOME="$TEST_HOME" bash "$SETUP" install 2>&1)"
ok 'warns from subdir via ancestor walk' \
   sh -c "printf '%s' \"\$1\" | grep -q 'overrides the user-level one'" _ "$sh_out"
rm -rf "$proj"

# ---- inner command with an unset var must not abort under the wrapper's set -u
reset_state
printf '%s' 'printf "X%sY" "$DEFINITELY_UNSET_VAR"' > "$guard_dir/statusline-inner"
ok 'inner with unset var still renders (no nounset abort)' \
   eq $'XY\n🔒 guard: armed' "$(wrap _ '')"

printf '\n%d passed, %d failed\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
