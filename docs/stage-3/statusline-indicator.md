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

**Review loop** — `code-reviewer-pro` subagent and the Codex CLI (gpt-5.5, read-only)
converged on four fixes, all applied: (High) `our_cmd="bash $wrapper_dst"` was
unquoted → broke when `$HOME` has spaces; the path is now double-quoted in the stored
command. (Med) the command string was interpolated into the jq filter → JSON injection
on `"`/`\` in the path; now passed via `--arg`/`--argjson`. (Med) `mktemp` created the
temp in `/tmp` → cross-filesystem `mv` is non-atomic; temp is now created beside
`settings.json` and removed on jq failure. (Med) malformed `settings.json` was treated
as "no status line"; `require_valid_settings` now refuses and errors. Added tests for a
spaced `$HOME` and malformed JSON (22 → 26 asserts). `eval` safety confirmed a non-issue
(inner is the user's own configured command).

A third reviewer (`agy`, Gemini 3.1 Pro) caught four more, all applied: (High) buffering
stdin via `input="$(cat)"` stripped the trailing newline before the inner status line —
now the inner command inherits the wrapper's stdin directly. (Med) `cp` overwrote the
active wrapper in place → a concurrent render could read a half-written file; now copied
via temp + `mv` (atomic). (Med) `mv` onto a symlinked `settings.json` (stow/yadm) replaced
the link with a regular file; `write_settings` now writes through a symlink. (Low)
`set -- $action` word-split/glob-expanded the argument; replaced with first-token
parameter expansion. Added stdin-newline and symlinked-settings tests (26 → 32 asserts).

Codex GitHub bot (PR #3, round 1) raised four, all addressed: (P2) the indicator
checked only file existence, so an expired timed bypass rendered `🔓` while the guard
was armed — both the wrapper and `status` now reuse the guard's flag-content check
(read-only, no cleanup). (P2) captured inner-command/object backups were world-readable
— guard dir is now `0700` and the backups `0600`. (P2) a project/local `statusLine`
silently shadows the user-level one — `install`/`status` now warn (user chose warn +
proceed over refuse/scope-write). (P3) install replaced the whole `.statusLine` object,
dropping siblings like `padding` — now merges. Tests 32 → 40.

Round 2 raised four more, all fixed: (P3) `git add -A` during development had swept
nine scratch probe files (`test-glob.sh`, `tmp`, `test-symlink/*`, …) into the commits;
since the marketplace packages `source: "."` they would ship — removed. (P2) the stored
wrapper command double-quoted the path, which a shell still re-expands (`$`, backticks);
now shell-escaped with `printf %q`. (P2) the symlink write path used `cat >` (non-atomic);
now resolves the link target and renames a temp onto it (atomic + link preserved). (P3)
the README manual snippet still checked file existence; updated to the content/expiry
check. Added shell-metacharacter-path test (40 → 41).

Round 3 raised four (all fixed; the 3-round cap was then reached): (P2) round 2's
symlink fix used GNU `readlink -f`, absent on macOS/BSD, so the fallback still replaced
the link — added a portable `resolve_symlink` (one-level POSIX `readlink`, chased in a
loop) with a `cat` write-through fallback that never clobbers the link. (P2) the wrapper
ran `eval "$inner"` under its own `set -u`, aborting inner status lines that reference
optional unset env vars — now evaluated in a `set +u` subshell. (P3) `warn_if_shadowed`
only checked `$PWD`, missing project settings when run from a subdirectory — now walks up
to the nearest ancestor `.claude/`. (P2) README uninstall guidance now tells status-line
users to run `/guard-statusline uninstall` before removing the plugin (else a stale
wrapper keeps rendering). Tests 41 → 43.

**Retrospective** — Composition (record inner → wrap → restore) is what makes this
conflict-free with any status line; the copy-to-stable-path step is the non-obvious
bit that keeps `settings.json` valid across plugin updates.
