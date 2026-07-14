# remote-guard — agent working notes

A Claude Code plugin that forces an explicit yes/no approval before any command
that reaches a real or remote server / cloud resource, so an agent cannot
silently touch infrastructure — even in auto / accept-edits modes.

**Cardinal rule: never under-protect.** When classification is uncertain, the
command is treated as the protected (write) class and the user is prompted. An
over-prompt is a nuisance; a silent bypass is the one failure this plugin exists
to prevent. Every change is judged against that rule first.

## What is guarded

- Remote/cloud CLIs matched in command position: `gcloud`, `gsutil`, `bq`, `aws`,
  `az`, `kubectl`, `ssh`, `scp`, `terraform`.
- Container tooling (`docker`, `podman`, `nerdctl`, and the hyphenated
  `*-compose` v1 binaries) **only for registry-bound operations**: `push` /
  `publish`, `login` / `logout`, `buildx imagetools create`, the buildx `--push`
  shorthand, and registry exporter / cache-write forms
  (`type=registry`, `push=true` on `--output` / `-o` / `--cache-to`). Local
  `build` / `run` / `ps` and read-only `pull` / `search` / `inspect` /
  `--cache-from` pass through silently.

Each matched command is classified **read** (`list`/`describe`/`get`/`show`/
`logs`/`plan`…) or **write** (`create`/`delete`/`apply`/`exec`/`ssh`/`scp`/
`bq query`… and anything unrecognized). `ssh`/`scp` and all container registry
ops are always write.

## Architecture

| File | Role |
|---|---|
| `scripts/guard-remote-ops.sh` | `PreToolUse` hook (matcher `Bash`). Reads hook JSON on stdin, matches + classifies `.tool_input.command`, emits `permissionDecision: "ask"` or stays silent. Fails **open** on error so a hiccup never blocks every shell command. |
| `scripts/guard-remote-toggle.sh` | Backs `/unguard`. Parses `[read\|write\|all\|off\|status] [duration\|persist]`, writes the bypass flags, reports state with remaining time. |
| `scripts/guard-remote-session-reset.sh` | `SessionStart` hook. Re-arms the guard by clearing session-scoped, expired, and unrecognized flags. |
| `scripts/guard-statusline*.sh` | `/guard-statusline` — composes a guard indicator on top of any existing status line. |
| `commands/unguard.md`, `commands/guard-statusline.md` | Slash commands (prompt files, not scripts). |
| `hooks/hooks.json` | Registers the two hooks. |

### The bypass-flag contract (the load-bearing invariant)

Two flag files live at `~/.claude/remote-guard/`: `bypass-read` and
`bypass-write`. **The file's contents encode the mode:**

| Contents | Meaning |
|---|---|
| empty | session-scoped — `SessionStart` clears it |
| digits | expiry epoch — active while `now < value`, survives restarts, auto-expires |
| `persist` | active until an explicit `/unguard off` |
| anything else | **inactive** — treated as OFF and cleaned up (never under-protect) |

Three places implement this check and must stay in agreement:
`flag_active()` in `guard-remote-ops.sh`, `state()` + `on()` in
`guard-remote-toggle.sh`, and the loop in `guard-remote-session-reset.sh`.
A flag that vanishes between the `[ -f ]` test and the `cat` must read as
inactive, not as an empty (active) session flag — that race was a real bug.

`/unguard` is `disable-model-invocation: true`: the model can never invoke it.
Only the user lowers the guard.

## Testing

```bash
bash tests/test-guard-remote-ops.sh      # 68 asserts — matching, classification, flag modes
bash tests/test-guard-remote-toggle.sh   # 26 asserts — duration parsing, persist, SessionStart reset
```

Both run under an isolated `HOME`, so real bypass flags never leak in. Every
behavior change needs a test here; regressions in this repo have historically
been *silent bypasses*, which only tests catch.

## Conventions

- Bash, `set -euo pipefail` in the toggle; the hook deliberately does **not**
  (it must fail open).
- Match the existing comment density — the regexes are load-bearing and each is
  explained above its definition. Don't strip those comments.
- Never commit to `main`. Branch (`feature/…`, `fix/…`, `docs/…`) → PR.
- Bump `version` in `.claude-plugin/plugin.json` for any behavior change; the
  plugin cache is keyed by version, so without a bump users won't get the update.
- Staged plan docs live in `docs/stage-N/<slug>.md`, indexed by `docs/summary.md`.

## Portability status — read before "adding Codex support"

This plugin is **Claude Code only** today. Codex CLI will *install* it and
report success while protecting nothing. See
[`docs/stage-5/codex-compatibility.md`](docs/stage-5/codex-compatibility.md)
for the measured evidence and the concrete work required. Do not assume the
hook fires just because `codex plugin add` succeeded.
