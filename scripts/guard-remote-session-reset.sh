#!/usr/bin/env bash
# guard-remote-session-reset.sh — SessionStart hook for the remote-guard plugin.
# Re-arms the guard on each new session, honoring the bypass mode encoded in the
# flag file contents (written by guard-remote-toggle.sh):
#   empty            -> session-scoped: removed (guard back on)
#   digits (epoch)   -> timed: kept while unexpired, removed once expired
#   "persist"        -> kept until an explicit /unguard off
#   anything else    -> unrecognized: removed (never under-protect)
# Always exits 0 so a hiccup never blocks session start.

dir="$HOME/.claude/remote-guard"
now=$(date +%s)

for f in "$dir/bypass-read" "$dir/bypass-write"; do
  [ -f "$f" ] || continue
  v=$(cat "$f" 2>/dev/null)
  case "$v" in
    persist) ;;
    ''|*[!0-9]*) rm -f "$f" ;;
    *) [ "$now" -lt "$v" ] || rm -f "$f" ;;
  esac
done

exit 0
