# Codex CLI compatibility — measured findings and handoff

**Status:** investigation only. No code changed. This document exists so the work
can be picked up in Codex CLI (or any other session) without re-deriving anything.

## Why

Doctor Cho asked whether remote-guard works in Codex CLI. It matters more than a
normal portability question: this plugin's whole purpose is to prevent a silent
bypass, so "installs but doesn't protect" is the worst possible outcome — worse
than not installing at all.

## What was measured

Tested against **Codex CLI 0.144.3** in a throwaway `CODEX_HOME` (the real
`~/.codex/config.toml` was verified untouched afterwards).

### The good news — Codex adopted much of the Claude Code plugin format

- `codex plugin marketplace add <repo>` reads our `.claude-plugin/marketplace.json`.
- `codex plugin add remote-guard@cho-plugins` **succeeds**, caching the plugin at
  `$CODEX_HOME/plugins/cache/cho-plugins/remote-guard/0.3.0` and writing
  `[plugins."remote-guard@cho-plugins"] enabled = true` to `config.toml`.
- Codex has the **same hook event names**: `PreToolUse`, `PostToolUse`,
  `SessionStart`, `PreCompact`, `PostCompact`, `SubagentStart`, `SubagentStop`.
- Codex uses the **same hook wire format**: input carries `tool_name` /
  `tool_input`; output honors `hookSpecificOutput` / `hookEventName` /
  `permissionDecision` / `permissionDecisionReason` / `systemMessage` / `continue`.

### The bad news — it installs and protects nothing

Three independent breakages, any one of which is fatal:

1. **Matcher mismatch.** `hooks/hooks.json` matches on `Bash`. Codex's shell tool
   is named `shell`, and under the model/config in use (`gpt-5.6-sol`, code mode)
   the actual call was a `custom_tool_call` named `exec`. `Bash` never matches, so
   the hook never runs.

2. **Payload shape mismatch.** Codex did not pass a command string in
   `tool_input.command`. The observed tool call embedded the command inside a
   JavaScript snippet:

   ```json
   {"type":"custom_tool_call","name":"exec",
    "input":"const r = await tools.exec_command({\"cmd\":\"echo HELLO_PROBE\",\"login\":false,...});"}
   ```

   `guard-remote-ops.sh` does `jq -r '.tool_input.command // empty'` → empty →
   `exit 0` → command runs unguarded. Note this shape is **model/feature
   dependent** (code mode vs. a plain `shell` tool), so any parser must handle
   more than one form.

3. **Hook trust.** Codex requires persisted hook trust (`trusted_hash`). Without
   it hooks are **silently skipped — no error, no warning**. A probe hook
   registered in `config.toml` never fired and said nothing about it. The escape
   hatch is `--dangerously-bypass-hook-trust`, which we deliberately did not use.

Separately, **`/unguard` cannot work in Codex at all**: the command is a prompt
file relying on Claude Code's `!` bash-execution line and the `AskUserQuestion`
tool, neither of which Codex has.

Net effect: in Codex, `plugin add` reports success, no error ever surfaces, and
`aws …` / `docker push …` run with no prompt.

## How to reproduce

```bash
export CODEX_HOME=$(mktemp -d ~/codex-test.XXXX)   # NOT /tmp — codex refuses PATH aliases there
cp ~/.codex/auth.json "$CODEX_HOME/"
codex plugin marketplace add /path/to/claude-remote-guard
codex plugin add remote-guard@cho-plugins          # succeeds
codex exec --sandbox read-only --skip-git-repo-check "Run exactly this shell command and nothing else: echo PROBE"
# then read the tool call that was actually issued:
python3 -c 'import json,sys
for l in open(sys.argv[1]):
    o=json.loads(l); p=o.get("payload",{})
    if p.get("type")=="custom_tool_call": print(json.dumps(p)[:400])' \
  "$CODEX_HOME"/sessions/*/*/*/rollout-*.jsonl
```

Codex's hook config lives in `config.toml`, not `hooks.json`:

```toml
[[hooks.PreToolUse]]
matcher = "shell"

[[hooks.PreToolUse.hooks]]
type = "command"          # variants seen in the binary: command | prompt | agent
command = "/abs/path/to/hook.sh"
```

## Open question (blocks the fix)

**The exact `PreToolUse` payload Codex delivers is still unverified.** We know
the field *names* (`tool_name`, `tool_input`) from the binary, but not what
`tool_input` contains for `shell` / `exec`. The probe hook never fired because of
hook trust, and confirming it requires either an interactive Codex session where
the trust prompt is accepted, or `--dangerously-bypass-hook-trust`.

**Do this first.** Everything below depends on the answer, and guessing here is
exactly how a silent bypass gets shipped.

## Work required for real Codex support

1. Capture the real `PreToolUse` payload for both a plain `shell` call and a
   code-mode `exec` call (see open question above).
2. Extract the command from every shape Codex can produce — at minimum
   `tool_input.command` (string), an argv array, and the code-mode JS
   `tools.exec_command({"cmd": "…"})`. **Fail closed on an unrecognized shape:**
   if the command cannot be extracted, prompt rather than pass. This inverts
   `guard-remote-ops.sh`'s current fail-open posture, which is only safe when a
   non-match genuinely means "not a shell command".
3. Register the hook for Codex's tool names (`shell`, `exec`) — either a second
   matcher or a Codex-specific `config.toml` block.
4. Replace `/unguard` for Codex: no `AskUserQuestion`, no `!` line. An
   argument-only command (or a plain script the user runs) is the realistic
   option. The interactive setup from stage 4 does not port.
5. Document the hook-trust step, since an untrusted hook fails silently and looks
   identical to a working one.
6. Decide whether one `guard-remote-ops.sh` serves both hosts or whether Codex
   gets its own entry point. One script with host detection keeps the
   classification logic (the valuable part) in a single place.

## Interim measure

Until the above lands, `README.md` states plainly that the plugin is Claude Code
only and that Codex will install it without protecting anything. That is the
cheap mitigation against a false sense of safety.

## Code locations

- `scripts/guard-remote-ops.sh` — `jq -r '.tool_input.command // empty'` and the
  fail-open `exit 0` are the two lines that break under Codex
- `hooks/hooks.json` — `matcher: "Bash"`
- `commands/unguard.md` — `!` line + `AskUserQuestion` (Claude Code only)
- `README.md` — portability note
- `AGENTS.md` — repo context for whichever agent picks this up

## Review loop

Findings were produced by direct measurement rather than a code diff, so no
reviewer subagent was run on code. The claims above are each backed by an
observed command output; the one thing explicitly **not** verified is called out
under "Open question" rather than being asserted.

## Retrospective

The surprise was how *close* Codex is — same event names, same wire format, reads
`.claude-plugin/` — which is exactly what makes it dangerous. Near-compatibility
produces a clean `plugin add` and zero errors while the guard is entirely absent.
The lesson for any future port: a successful install is not evidence of
protection. Prove the hook fires before believing it works.
