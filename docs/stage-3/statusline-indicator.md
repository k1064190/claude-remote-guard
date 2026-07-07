# Status-line indicator via composition

**Why** — Users wanted the guard state (armed vs bypassed) visible in the status
line, but Claude Code renders a single `statusLine.command` and gives plugins no
way to register, stack, or append to it. The old README told users to hand-edit
their own status-line script — brittle, and impossible for anyone running a
status-line plugin (e.g. claude-dashboard) that owns the whole line.

**What** — `/guard-statusline [install|uninstall|status]`:

- `install` → composes the guard line on top of whatever status line you already
  have; repoints `statusLine` at a wrapper. Idempotent (re-run to refresh).
- `uninstall` → restores the original `statusLine` object verbatim.
- `status` → reports the current wiring and guard state.
- Renders `🔒 guard: armed` / `🔓 guard: R|W|RW bypass` on its own final line.

**How** — Two scripts. `statusline-guard.sh` is the render-time wrapper: it buffers
the status-line JSON from stdin, runs the recorded "inner" command with that stdin
unchanged (`eval`, since it is the exact string Claude Code would have run), prints
its output, then appends the guard line read from the same `bypass-read|write`
marker files the rest of the plugin uses. `guard-statusline-setup.sh` does the
one-time wiring with `jq`: it saves the current `statusLine.command` (string, for the
wrapper) and the full `.statusLine` object (for exact restore), copies the wrapper to
a **stable** path (`~/.claude/remote-guard/statusline.sh`) so the settings entry
survives plugin version bumps, then sets `statusLine` to `bash <stable-wrapper>`.
Install is idempotent (detects its own wrapper command and only refreshes the copy,
never nesting), and uninstall on a foreign status line is a no-op. Auto-install on
plugin install is impossible (no supported hook edits `settings.json`), so the
command is the minimum required user action; it is `disable-model-invocation`.

**Code locations**

- `scripts/statusline-guard.sh` — render-time composition wrapper (stdin passthrough + guard line)
- `scripts/guard-statusline-setup.sh` — install/uninstall/status; jq settings edit, stable-path copy, idempotency, exact restore
- `commands/guard-statusline.md` — slash command (Bash, `disable-model-invocation`), mirrors `unguard.md`
- `tests/test-guard-statusline.sh` — 22 asserts (wrapper composition + stdin passthrough + install/idempotency/uninstall/restore/no-op)
- `README.md` — "Optional: status-line indicator" rewritten around the command; manual snippet kept as a fallback

**Review loop** — _(pending: code-reviewer subagent + antigravity/codex skills + Codex PR bot)_

**Retrospective** — Composition (record inner → wrap → restore) is what makes this
conflict-free with any status line; the copy-to-stable-path step is the non-obvious
bit that keeps `settings.json` valid across plugin updates.
