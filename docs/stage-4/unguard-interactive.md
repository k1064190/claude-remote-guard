# /unguard interactive setup (no-argument mode)

**Why** — Bare `/unguard` only printed the state; configuring still required
remembering the argument syntax (`write 30m`, `all persist`, …). Doctor Cho
wanted a no-argument call to walk through the setup interactively.

**What** — `/unguard` with no arguments now: shows the current state, then asks
one AskUserQuestion with two questions — **Action** (write / read / all / off,
already-ON options marked) and **Scope** (이번 세션만 / 30m / 2h / persist,
"Other" passes custom durations like `45m` through) — and runs the toggle with
the selection. With arguments, behavior is unchanged (relay only).
`/unguard status` stays the question-free way to just look.

**How** — Command-markdown-only change: the `!` line already renders the passed
arguments, so the instructions branch on whether the quoted string is empty.
`allowed-tools` gained `AskUserQuestion`. The model is instructed to never pick
an action/scope on its own — `disable-model-invocation` still keeps the model
from invoking the command at all. No script changes; both test suites unchanged
and green (68 + 26).

**Code locations**

- `commands/unguard.md` — interactive branch instructions, allowed-tools
- `README.md` — usage lines for bare `/unguard` and `/unguard status`
- `.claude-plugin/plugin.json` — version 0.3.0

**Review loop** — Codex GitHub bot on PR: see PR record. (Prompt-only diff;
no shell code changed.)

**Retrospective** — The slash-command markdown is itself the interface layer,
so "interactivity" belongs there, not in the bash script.
