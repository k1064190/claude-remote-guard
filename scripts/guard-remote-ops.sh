#!/usr/bin/env bash
# guard-remote-ops.sh — PreToolUse hook (matcher: Bash) for the remote-guard plugin.
# Forces an explicit yes/no approval before any command that reaches a real or
# remote server / cloud resource via gcloud, gsutil, bq, aws, az, kubectl, ssh,
# scp, or terraform -- including read-only queries (조회).
#
# Each matched command is classified read vs write so the /unguard toggles can
# bypass the two classes independently (see scripts/guard-remote-toggle.sh).
#
# Input : hook JSON on stdin; .tool_input.command holds the bash command.
# Output: on a match (and no matching bypass), permissionDecision "ask"; otherwise
#         nothing, so normal permission handling proceeds. Fails open on error so a
#         hiccup never blocks every shell command.

read_flag="$HOME/.claude/remote-guard/bypass-read"
write_flag="$HOME/.claude/remote-guard/bypass-write"

command=$(jq -r '.tool_input.command // empty')

# Match the CLI only in command position -- at the start, after whitespace, or after
# a shell separator (| & ; ( =) -- so substrings like ~/.ssh, "bazel", or "awscli"
# do not trigger a false prompt.
remote_re='(^|[[:space:]]|[;|&(=])(gcloud|gsutil|bq|aws|az|kubectl|ssh|scp|terraform)([[:space:]]|$)'
printf '%s' "$command" | grep -Eq "$remote_re" || exit 0

# Classify read-only vs write/dangerous. Write is checked first so a command that
# mixes verbs is treated as write; ssh/scp and anything unrecognized are write too.
write_re='(^|[^[:alnum:]_-])(create|delete|update|patch|apply|edit|set|add|remove|rm|put|deploy|destroy|run|exec|scale|rollout|drain|cordon|uncordon|taint|untaint|import|cp|mv|sync|rsync|mb|rb|terminate|stop|start|restart|reboot|modify|attach|detach|associate|disassociate|authorize|revoke|enable|disable|register|deregister|grant|reset|load|insert|publish|push|init|refresh|query|cancel|purge|restore|tag|untag)([^[:alnum:]_]|$)'
read_re='(^|[^[:alnum:]_-])(list|describe|get|show|ls|cat|stat|du|head|view|read|plan|output|outputs|validate|version|explain|top|log|logs|status|info|history|search|scan|hash|graph|providers|exists|check)([^[:alnum:]_]|$)'
sshscp_re='(^|[[:space:]]|[;|&(=])(ssh|scp)([[:space:]]|$)'

if printf '%s' "$command" | grep -Eiq "$sshscp_re"; then
  kind=write
elif printf '%s' "$command" | grep -Eiq "$write_re"; then
  kind=write
elif printf '%s' "$command" | grep -Eiq "$read_re"; then
  kind=read
else
  kind=write
fi

# Session-scoped bypass flags set by /unguard; a SessionStart hook clears them each
# new session. read flag -> skip prompt for read-only; write flag -> skip for write.
if [ "$kind" = read ]  && [ -f "$read_flag"  ]; then exit 0; fi
if [ "$kind" = write ] && [ -f "$write_flag" ]; then exit 0; fi

cli=$(printf '%s' "$command" | grep -Eo "$remote_re" \
      | grep -Eo '(gcloud|gsutil|bq|aws|az|kubectl|ssh|scp|terraform)' | head -n1)
reason="Remote/cloud operation ('$cli', classified $kind) — review the exact command, then approve (yes) or reject (no)."
jq -n --arg r "$reason" \
  '{hookSpecificOutput:{hookEventName:"PreToolUse",permissionDecision:"ask",permissionDecisionReason:$r}}'

exit 0
