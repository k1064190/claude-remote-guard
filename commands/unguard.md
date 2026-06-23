---
description: Toggle the remote/cloud approval guard for this session — read(조회) and write(위험) separately (auto-resets on restart). Usage:/unguard [read|write|all|off|status]
argument-hint: [read|write|all|off|status]
allowed-tools: Bash
disable-model-invocation: true
---
! "${CLAUDE_PLUGIN_ROOT}"/scripts/guard-remote-toggle.sh "$ARGUMENTS"

Relay the result lines above to me as the new guard state, concisely. Do not run any other tools or commands.
