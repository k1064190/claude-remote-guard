---
description: Show the remote-guard state in your status line by composing on top of your existing status line. Usage:/guard-statusline [install|uninstall|status]
argument-hint: [install|uninstall|status]
allowed-tools: Bash
disable-model-invocation: true
---
! "${CLAUDE_PLUGIN_ROOT}"/scripts/guard-statusline-setup.sh "$ARGUMENTS"

Relay the result lines above to me concisely as the new status-line state. Do not run any other tools or commands.
