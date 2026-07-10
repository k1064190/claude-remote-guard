---
description: Toggle the remote/cloud approval guard — read(조회) and write(위험) separately. Session-scoped by default (resets on restart); add a duration (30m/2h) or persist to survive restarts. No arguments = interactive setup. Usage:/unguard [read|write|all|off|status] [30m|2h|persist]
argument-hint: [read|write|all|off|status] [30m|2h|persist]
allowed-tools: Bash, AskUserQuestion
disable-model-invocation: true
---
! "${CLAUDE_PLUGIN_ROOT}"/scripts/guard-remote-toggle.sh "$ARGUMENTS"

The line above shows the arguments I passed (the quoted string after guard-remote-toggle.sh).

**If I passed arguments** (the quoted string is non-empty): relay the result lines above to me as the new guard state, concisely. Do not run any other tools or commands.

**If I passed no arguments** (the quoted string is empty, so the output above is just the current state): help me configure the bypass interactively —

1. Relay the current state in one line.
2. Ask me with a single AskUserQuestion call containing two questions:
   - **Action** — which bypass to change: `write`(변경·삭제·ssh), `read`(조회), `all`(둘 다 함께 토글 — 하나라도 ON이면 둘 다 OFF가 됨), or `off`(모두 해제, 가드 원상복구). Mark options that are already ON in their descriptions.
   - **Scope** — how long the bypass should last: `이번 세션만` (default; resets on restart), `30m`, `2h`, or `persist` (until /unguard off). Note in the question that this is ignored if Action is `off`.
3. Then run exactly one command and nothing else:
   `"${CLAUDE_PLUGIN_ROOT}"/scripts/guard-remote-toggle.sh "<action> <scope>"` — omit `<scope>` when the action is `off` or the scope is 이번 세션만. A custom "Other" scope is accepted ONLY if it matches `^[0-9]{1,6}[hms]?$` (e.g. `45m`) or is exactly `persist`; anything else (quotes, spaces, `$`, backticks, words) must NOT be placed in the command — refuse and re-ask instead.
4. Relay the resulting state lines concisely.

Never choose an action or scope on my behalf; only act on my explicit selection. Do not run any other tools or commands.
