#!/usr/bin/env bash
# guard-statusline-setup.sh [install|uninstall|status] — remote-guard plugin.
#
# Composes the remote-guard status indicator on top of the user's existing
# status line. Claude Code allows only one `statusLine.command` in settings.json
# and offers no plugin hook to register or stack status lines, so this wires the
# composition wrapper in explicitly (a one-time, reversible edit of settings.json).
#
#   install   — record the current statusLine as the "inner" line and repoint
#               settings.json at the wrapper (idempotent; safe to re-run to
#               refresh the wrapper after a plugin update).
#   uninstall — restore the exact statusLine that was there before install.
#   status    — report the current wiring and guard state.
#
# The wrapper is copied to a stable path ($HOME/.claude/remote-guard/statusline.sh)
# so the settings.json entry survives plugin version bumps, whose install path
# changes. Re-run `install` after an update to pick up wrapper logic changes.
set -euo pipefail

guard_dir="$HOME/.claude/remote-guard"
settings="$HOME/.claude/settings.json"
src_dir="$(cd "$(dirname "$0")" && pwd)"
wrapper_src="$src_dir/statusline-guard.sh"
wrapper_dst="$guard_dir/statusline.sh"
inner_cmd_file="$guard_dir/statusline-inner"        # command string for the wrapper to eval
inner_obj_file="$guard_dir/statusline-inner.json"   # full original object for exact restore

mkdir -p "$guard_dir"
our_cmd="bash $wrapper_dst"

# current_cmd -> prints the configured statusLine.command ("" if none / no file).
current_cmd() {
    [ -f "$settings" ] || { printf ''; return; }
    jq -r '.statusLine.command // ""' "$settings" 2>/dev/null || printf ''
}

# write_settings <jq-filter> — apply a jq transform to settings.json atomically,
# creating the file as {} if it does not exist yet.
write_settings() {
    local filter="$1" tmp
    [ -f "$settings" ] || printf '{}\n' > "$settings"
    tmp="$(mktemp)"
    jq "$filter" "$settings" > "$tmp"
    mv "$tmp" "$settings"
}

guard_state() {
    local gr="" gw=""
    [ -f "$guard_dir/bypass-read" ]  && gr="R"
    [ -f "$guard_dir/bypass-write" ] && gw="W"
    if [ -n "$gr$gw" ]; then echo "🔓 bypass:$gr$gw"; else echo "🔒 armed"; fi
}

action="${1:-status}"
# The slash command hands arguments over as one word; keep only the first token.
# shellcheck disable=SC2086
set -- $action
action="${1:-status}"

case "$action" in
install)
    cur="$(current_cmd)"
    if [ "$cur" = "$our_cmd" ]; then
        # Already wired — just refresh the wrapper copy (logic may have changed).
        cp "$wrapper_src" "$wrapper_dst"; chmod +x "$wrapper_dst"
        echo "remote-guard status line already installed — wrapper refreshed."
    else
        # Capture whatever is there now as the inner status line, then take over.
        printf '%s' "$cur" > "$inner_cmd_file"
        if [ -f "$settings" ]; then
            jq '.statusLine // null' "$settings" > "$inner_obj_file"
        else
            printf 'null\n' > "$inner_obj_file"
        fi
        cp "$wrapper_src" "$wrapper_dst"; chmod +x "$wrapper_dst"
        write_settings ".statusLine = {\"type\":\"command\",\"command\":\"$our_cmd\"}"
        if [ -n "$cur" ]; then
            echo "remote-guard status line installed — wrapping your existing status line:"
            echo "  inner: $cur"
        else
            echo "remote-guard status line installed (no previous status line — guard line only)."
        fi
    fi
    echo "  state: $(guard_state)"
    ;;
uninstall)
    cur="$(current_cmd)"
    if [ "$cur" != "$our_cmd" ]; then
        echo "remote-guard status line is not currently installed — nothing to do."
        echo "  current statusLine.command: ${cur:-<none>}"
        exit 0
    fi
    if [ -f "$inner_obj_file" ] && [ "$(cat "$inner_obj_file")" != "null" ]; then
        write_settings ".statusLine = $(cat "$inner_obj_file")"
        echo "remote-guard status line removed — restored your previous status line."
    else
        write_settings "del(.statusLine)"
        echo "remote-guard status line removed — no previous status line to restore."
    fi
    rm -f "$inner_cmd_file" "$inner_obj_file" "$wrapper_dst"
    ;;
status)
    cur="$(current_cmd)"
    if [ "$cur" = "$our_cmd" ]; then
        echo "remote-guard status line: INSTALLED"
        echo "  wrapper: $our_cmd"
        echo "  inner  : $([ -s "$inner_cmd_file" ] && cat "$inner_cmd_file" || echo '<none>')"
    else
        echo "remote-guard status line: not installed"
        echo "  current statusLine.command: ${cur:-<none>}"
        echo "  run: /guard-statusline install"
    fi
    echo "  state  : $(guard_state)"
    ;;
*)
    echo "Usage: /guard-statusline [install|uninstall|status]"
    exit 2
    ;;
esac
