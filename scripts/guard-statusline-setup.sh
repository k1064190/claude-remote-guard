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

mkdir -p "$guard_dir"; chmod 700 "$guard_dir" 2>/dev/null || true
# Shell-escape the path (not just double-quote it) so the stored command is
# safe even when $HOME contains spaces, $, backticks, or quotes — a shell later
# re-parses this string, and double quotes alone would re-expand $var/`cmd`.
# This exact string is stored in settings.json and eval'd by the wrapper as the
# inner command, so both Claude Code and the wrapper honour the quoting.
our_cmd="bash $(printf '%q' "$wrapper_dst")"

# require_valid_settings — refuse to touch a settings.json that exists but is not
# valid JSON, rather than silently treating it as "no status line" and writing
# partial state on top of a file we can't safely restore.
require_valid_settings() {
    if [ -f "$settings" ] && ! jq -e . "$settings" >/dev/null 2>&1; then
        echo "error: $settings is not valid JSON — fix it before running /guard-statusline." >&2
        exit 1
    fi
}

# current_cmd -> prints the configured statusLine.command ("" if none / no file).
current_cmd() {
    [ -f "$settings" ] || { printf ''; return; }
    jq -r '.statusLine.command // ""' "$settings" 2>/dev/null || printf ''
}

# write_settings <jq-args...> — apply a jq program (args + filter) to
# settings.json atomically, creating the file as {} if absent. The settings path
# is appended automatically; the temp file is created alongside settings.json so
# the final mv is a same-filesystem atomic rename (mktemp in /tmp could be a
# cross-device copy). Temp file is removed if jq fails so nothing leaks.
# resolve_symlink <path> -> prints the final target of a symlink chain, or fails.
# Portable (uses one-level POSIX `readlink`, present on macOS/BSD and Linux)
# instead of GNU-only `readlink -f`. Resolves each level relative to its link's
# directory; bails out after 40 hops to avoid a cyclic-link infinite loop.
resolve_symlink() {
    local link="$1" target i=0
    while [ -L "$link" ]; do
        [ "$i" -lt 40 ] || return 1
        i=$((i + 1))
        target="$(readlink "$link")" || return 1
        case "$target" in
            /*) link="$target" ;;
            *)  link="$(cd "$(dirname "$link")" && cd "$(dirname "$target")" 2>/dev/null && pwd)/$(basename "$target")" ;;
        esac
    done
    printf '%s' "$link"
}

write_settings() {
    local dest tmp
    [ -e "$settings" ] || printf '{}\n' > "$settings"
    # For a managed-dotfile symlink (stow/yadm/chezmoi) write to its real target
    # so the link itself is preserved. Resolving the target lets us rename a temp
    # onto it atomically; if resolution fails, write through the link with `cat`
    # (non-atomic, but never replaces the link with a regular file).
    if [ -L "$settings" ] && dest="$(resolve_symlink "$settings")" && [ -n "$dest" ]; then
        tmp="$(mktemp "$dest.XXXXXX")" || return 1
        if ! jq "$@" "$settings" > "$tmp"; then rm -f "$tmp"; return 1; fi
        mv "$tmp" "$dest"                       # atomic rename onto the real file
    elif [ -L "$settings" ]; then
        tmp="$(mktemp "$settings.XXXXXX")" || return 1
        if ! jq "$@" "$settings" > "$tmp"; then rm -f "$tmp"; return 1; fi
        cat "$tmp" > "$settings" && rm -f "$tmp"  # write through the link
    else
        tmp="$(mktemp "$settings.XXXXXX")" || return 1
        if ! jq "$@" "$settings" > "$tmp"; then rm -f "$tmp"; return 1; fi
        mv "$tmp" "$settings"                   # atomic same-filesystem replace
    fi
}

# install_wrapper — copy the wrapper to its stable path atomically (temp + mv),
# so a status-line render already executing the old wrapper keeps reading its
# inode instead of a half-written file being overwritten in place.
install_wrapper() {
    cp "$wrapper_src" "$wrapper_dst.new"
    chmod +x "$wrapper_dst.new"
    mv "$wrapper_dst.new" "$wrapper_dst"
}

# flag_active <file> — read-only mirror of guard-remote-ops.sh's bypass check
# (empty/persist = active, digits = expiry epoch, else inactive) so `status`
# agrees with what the guard enforces and never shows a stale expired bypass.
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

guard_state() {
    local gr="" gw=""
    flag_active "$guard_dir/bypass-read"  && gr="R"
    flag_active "$guard_dir/bypass-write" && gw="W"
    if [ -n "$gr$gw" ]; then echo "🔓 bypass:$gr$gw"; else echo "🔒 armed"; fi
}

# warn_if_shadowed — Claude Code applies project/local settings above the
# user-level file this script edits, so a statusLine defined in the current
# project would shadow the wrapper and the guard line would never render. We
# only touch the user file (writing the guard command into a project's
# .claude/settings.json could leak into the repo), so warn and let the user
# resolve it rather than silently reporting a success that has no visible effect.
warn_if_shadowed() {
    local dir="$PWD" f
    # Claude Code takes the nearest ancestor `.claude/` as the project root, so
    # walk up from the current directory (install may run in a subdirectory)
    # until we hit one, then check only that project's settings for a statusLine.
    while :; do
        if [ -d "$dir/.claude" ]; then
            for f in "$dir/.claude/settings.local.json" "$dir/.claude/settings.json"; do
                if [ -f "$f" ] && jq -e 'has("statusLine") and .statusLine != null' "$f" >/dev/null 2>&1; then
                    echo "warning: $f defines a statusLine that overrides the user-level one;"
                    echo "         the guard line will not appear in this project until that entry is removed."
                fi
            done
            return
        fi
        [ "$dir" = "/" ] && return
        dir="$(dirname "$dir")"
    done
}

# The slash command hands arguments over as one word; keep only the first token,
# without word-splitting or glob expansion (a bare `*` must not expand to files).
action="${1:-status}"
action="${action%% *}"
action="${action:-status}"

case "$action" in
install)
    require_valid_settings
    warn_if_shadowed
    cur="$(current_cmd)"
    if [ "$cur" = "$our_cmd" ]; then
        # Already wired — just refresh the wrapper copy (logic may have changed).
        install_wrapper
        echo "remote-guard status line already installed — wrapper refreshed."
    else
        # Capture whatever is there now as the inner status line, then take over.
        # The captured state can echo private command arguments from the user's
        # settings, so keep these backups owner-only (0600 under a 0700 dir).
        printf '%s' "$cur" > "$inner_cmd_file"; chmod 600 "$inner_cmd_file"
        if [ -f "$settings" ]; then
            jq '.statusLine // null' "$settings" > "$inner_obj_file"
        else
            printf 'null\n' > "$inner_obj_file"
        fi
        chmod 600 "$inner_obj_file"
        install_wrapper
        # Merge over the existing statusLine so sibling display options (e.g.
        # statusLine.padding) are preserved while the wrapper is installed.
        write_settings --arg cmd "$our_cmd" '.statusLine = ((.statusLine // {}) + {type: "command", command: $cmd})'
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
    require_valid_settings
    cur="$(current_cmd)"
    if [ "$cur" != "$our_cmd" ]; then
        echo "remote-guard status line is not currently installed — nothing to do."
        echo "  current statusLine.command: ${cur:-<none>}"
        exit 0
    fi
    if [ -f "$inner_obj_file" ] && [ "$(cat "$inner_obj_file")" != "null" ]; then
        write_settings --argjson obj "$(cat "$inner_obj_file")" '.statusLine = $obj'
        echo "remote-guard status line removed — restored your previous status line."
    else
        write_settings 'del(.statusLine)'
        echo "remote-guard status line removed — no previous status line to restore."
    fi
    rm -f "$inner_cmd_file" "$inner_obj_file" "$wrapper_dst"
    ;;
status)
    warn_if_shadowed
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
