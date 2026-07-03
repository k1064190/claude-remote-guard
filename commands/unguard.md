---
description: Toggle the remote/cloud approval guard — read(조회) and write(위험) separately. Session-scoped by default (resets on restart); add a duration (30m/2h) or persist to survive restarts. Usage:/unguard [read|write|all|off|status] [30m|2h|persist]
argument-hint: [read|write|all|off|status] [30m|2h|persist]
allowed-tools: Bash
disable-model-invocation: true
---
! "${CLAUDE_PLUGIN_ROOT}"/scripts/guard-remote-toggle.sh "$ARGUMENTS"

Relay the result lines above to me as the new guard state, concisely. Do not run any other tools or commands.
