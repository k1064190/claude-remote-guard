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

# Claude Code feeds the status-line JSON on stdin. Buffer it so it can be passed
# through to the inner status line unchanged (the guard part ignores it).
input="$(cat)"

# Run the previously-configured ("inner") status line, if one was captured at
# install time. Command substitution strips its trailing newline so the guard
# line always attaches as a clean final line. `eval` is required to honour the
# inner command's own arguments; it is the exact string Claude Code would have
# run itself, so this introduces no new trust boundary.
if [ -s "$inner_file" ]; then
    inner="$(cat "$inner_file")"
    out="$(printf '%s' "$input" | eval "$inner")"
    printf '%s' "$out"
    [ -n "$out" ] && printf '\n'
fi

# remote-guard indicator. Armed unless a bypass marker file exists (the same
# flags guard-remote-ops.sh / guard-remote-toggle.sh read and write).
gr=""; [ -f "$guard_dir/bypass-read" ]  && gr="R"
gw=""; [ -f "$guard_dir/bypass-write" ] && gw="W"
if [ -n "$gr$gw" ]; then
    printf '🔓 guard: %s bypass' "$gr$gw"
else
    printf '🔒 guard: armed'
fi
