#!/usr/bin/env bash
# statusline-guard.sh — remote-guard status-line composition wrapper.
#
# Claude Code renders a single status line (settings.json `statusLine.command`),
# so a plugin cannot own or append to it directly. `/guard-statusline install`
# points that one command at this wrapper and records whatever command was there
# before as the "inner" status line. On every render this wrapper runs the inner
# status line unchanged, then appends the remote-guard armed/bypass indicator on
# its own final line — composing on top of ANY existing status line (dashboard,
# starship-based, custom) without conflict.
#
# Reads only files under $HOME/.claude/remote-guard, so it never needs
# CLAUDE_PLUGIN_ROOT (which is absent when Claude Code runs the status line).
set -u

guard_dir="$HOME/.claude/remote-guard"
inner_file="$guard_dir/statusline-inner"

# Run the previously-configured ("inner") status line, if one was captured at
# install time. The inner command inherits this wrapper's stdin (the status-line
# JSON from Claude Code) directly — no buffering — so a trailing newline is
# preserved for inner commands that read line-by-line. Command substitution
# strips the inner *output*'s trailing newline so the guard line always attaches
# as a clean final line. `eval` honours the inner command's own arguments; it is
# the exact string Claude Code would have run itself, so it adds no trust boundary.
if [ -s "$inner_file" ]; then
    inner="$(cat "$inner_file")"
    # Evaluate with nounset OFF (scoped to this subshell): Claude Code runs the
    # status line without `set -u`, and inner commands may reference optional,
    # possibly-unset env vars — inheriting our nounset would abort them and drop
    # the user's status line, leaving only the guard line.
    out="$(set +u; eval "$inner")"
    printf '%s' "$out"
    [ -n "$out" ] && printf '\n'
fi

# flag_active <file> — mirror guard-remote-ops.sh's bypass semantics so the
# indicator matches what the guard actually enforces: file contents encode the
# mode (empty/persist = active, digits = expiry epoch active only until then,
# anything else = inactive). Read-only: unlike the guard's own copy this never
# deletes expired flags — the status line only observes, it doesn't mutate state.
flag_active() {
    local v
    [ -f "$1" ] || return 1
    v="$(cat "$1" 2>/dev/null)" || return 1
    case "$v" in
        ''|persist) return 0 ;;
        *[!0-9]*)   return 1 ;;
        *)          [ "$(date +%s)" -lt "$v" ] ;;
    esac
}

# remote-guard indicator. Armed unless a bypass flag is actually active (an
# expired timed bypass still on disk reads as armed, matching the guard).
gr=""; flag_active "$guard_dir/bypass-read"  && gr="R"
gw=""; flag_active "$guard_dir/bypass-write" && gw="W"
if [ -n "$gr$gw" ]; then
    printf '🔓 guard: %s bypass' "$gr$gw"
else
    printf '🔒 guard: armed'
fi
