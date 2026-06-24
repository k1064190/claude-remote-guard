#!/usr/bin/env bash
# guard-remote-ops.sh — PreToolUse hook (matcher: Bash) for the remote-guard plugin.
# Forces an explicit yes/no approval before any command that reaches a real or
# remote server / cloud resource via gcloud, gsutil, bq, aws, az, kubectl, ssh,
# scp, or terraform -- including read-only queries (조회). It also guards container
# image tooling (docker/podman/nerdctl), but only for registry-bound operations --
# push and login/logout -- so local build/run and read-only pull/search stay quiet.
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

# Container image tooling (docker/podman/nerdctl, incl. the hyphenated *-compose v1
# binaries) is used mostly for local work, so only registry-bound operations are
# guarded: outbound push (incl. `image push`, `manifest push`, compose `push`) and
# credential login/logout. Local build/run and read-only pull/search pass through.
# The op must sit in the same command segment as the CLI ([^;|&]*). The trailing
# boundary [[:space:];|&)] (or end) treats whitespace, a shell separator, or a
# subshell ')' as a token end -- so `docker compose push`, `docker logout`, and
# `(docker login)` still match when the verb is the last token, while substrings
# like `run pushgateway` or `--network login-net` stay quiet. `--push` (buildx) is
# matched apart since it is a flag, not a subcommand. (Like the remote_re above, this
# does not see into nested shells such as `bash -c "..."` or absolute-path invocations.)
#
# Newlines/tabs are flattened to spaces first so a line-continued command -- e.g. a
# multi-line `docker buildx build` with `--push` on its own line -- still matches.
scan=$(printf '%s' "$command" | tr '\n\t' '  ')
container_re='(^|[[:space:]]|[;|&(=])(docker|podman|nerdctl|docker-compose|podman-compose)[[:space:]]([^;|&]*[[:space:]])?(push|login|logout)([[:space:];|&)]|$)'
container_pushflag_re='(^|[[:space:]]|[;|&(=])(docker|podman|nerdctl|docker-compose|podman-compose)[[:space:]][^;|&]*--push([[:space:]=;|&)]|$)'

is_container=0
if printf '%s' "$scan" | grep -Eiq "$container_re" \
   || printf '%s' "$scan" | grep -Eiq "$container_pushflag_re"; then
  is_container=1
fi

# Nothing remote and no guarded container op -> let normal permission handling proceed.
[ "$is_container" = 1 ] || printf '%s' "$command" | grep -Eq "$remote_re" || exit 0

# Classify read-only vs write/dangerous. Write is checked first so a command that
# mixes verbs is treated as write; ssh/scp and anything unrecognized are write too.
write_re='(^|[^[:alnum:]_-])(create|delete|update|patch|apply|edit|set|add|remove|rm|put|deploy|destroy|run|exec|scale|rollout|drain|cordon|uncordon|taint|untaint|import|cp|mv|sync|rsync|mb|rb|terminate|stop|start|restart|reboot|modify|attach|detach|associate|disassociate|authorize|revoke|enable|disable|register|deregister|grant|reset|load|insert|publish|push|init|refresh|query|cancel|purge|restore|tag|untag)([^[:alnum:]_]|$)'
read_re='(^|[^[:alnum:]_-])(list|describe|get|show|ls|cat|stat|du|head|view|read|plan|output|outputs|validate|version|explain|top|log|logs|status|info|history|search|scan|hash|graph|providers|exists|check)([^[:alnum:]_]|$)'
sshscp_re='(^|[[:space:]]|[;|&(=])(ssh|scp)([[:space:]]|$)'

if [ "$is_container" = 1 ]; then
  kind=write                       # push / login / logout reach or mutate a remote registry
elif printf '%s' "$command" | grep -Eiq "$sshscp_re"; then
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

if [ "$is_container" = 1 ]; then
  cli=$(printf '%s' "$scan" | grep -Eio '(^|[[:space:]]|[;|&(=])(docker-compose|podman-compose|docker|podman|nerdctl)[[:space:]]' \
        | grep -Eio '(docker-compose|podman-compose|docker|podman|nerdctl)' | head -n1)
  op_label="Container registry operation"
else
  cli=$(printf '%s' "$command" | grep -Eo "$remote_re" \
        | grep -Eo '(gcloud|gsutil|bq|aws|az|kubectl|ssh|scp|terraform)' | head -n1)
  op_label="Remote/cloud operation"
fi
reason="$op_label ('$cli', classified $kind) — review the exact command, then approve (yes) or reject (no)."
jq -n --arg r "$reason" \
  '{hookSpecificOutput:{hookEventName:"PreToolUse",permissionDecision:"ask",permissionDecisionReason:$r}}'

exit 0
