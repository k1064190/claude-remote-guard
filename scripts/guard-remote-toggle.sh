#!/usr/bin/env bash
# guard-remote-toggle.sh [read|write|all|off|status] — remote-guard plugin.
# Toggles session-scoped bypass flags read by guard-remote-ops.sh:
#   read  flag -> read-only remote/cloud queries (list/describe/get/show/logs/plan...)
#                 run WITHOUT a prompt.
#   write flag -> write/dangerous commands (create/delete/update/apply/exec/ssh/scp/
#                 bq query...) run WITHOUT a prompt.
# No argument just reports the current state. A SessionStart hook removes both flags
# on each new session, so any bypass resets on restart.
set -euo pipefail

dir="$HOME/.claude/remote-guard"
read_flag="$dir/bypass-read"
write_flag="$dir/bypass-write"
mkdir -p "$dir"

state() { [ -f "$1" ] && echo ON || echo OFF; }
flip()  { if [ -f "$1" ]; then rm -f "$1"; else : > "$1"; fi; }

case "${1:-status}" in
  read)   flip "$read_flag" ;;
  write)  flip "$write_flag" ;;
  all)    if [ -f "$read_flag" ] || [ -f "$write_flag" ]; then
            rm -f "$read_flag" "$write_flag"          # any on -> turn both off
          else
            : > "$read_flag"; : > "$write_flag"       # both off -> turn both on
          fi ;;
  off|reset) rm -f "$read_flag" "$write_flag" ;;
  status) ;;
  *) echo "Usage: /unguard [read|write|all|off|status]"; exit 0 ;;
esac

echo "Remote/cloud guard bypass (this session) — read(조회): $(state "$read_flag")  |  write(변경·삭제·ssh): $(state "$write_flag")"
echo "  read ON  = list/describe/get/show/logs/plan ... run without a prompt"
echo "  write ON = create/delete/update/apply/exec/ssh/scp/bq query ... run without a prompt"
echo "  Resets automatically on restart.  Toggle: /unguard read | write | all | off"
