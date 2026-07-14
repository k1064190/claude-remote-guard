# Project stages — remote-guard plugin

## Stage 1 — Guard container-registry push/login
- [container-registry-guard](stage-1/container-registry-guard.md) — docker/podman/nerdctl registry-bound ops (push/publish/login/logout, buildx exporters) now prompt; local build/run/pull stay quiet.

## Stage 2 — Timed & persistent /unguard bypasses
- [unguard-ttl-persist](stage-2/unguard-ttl-persist.md) — `/unguard <class> 30m|2h|persist` survives restarts (TTL auto-re-arms, max 24h); flag contents encode the mode; SessionStart clears only session-scoped/expired flags.

## Stage 3 — Status-line indicator
- [statusline-indicator](stage-3/statusline-indicator.md) — `/guard-statusline install` composes a `🔒 guard: armed` / `🔓 bypass` line on top of any existing status line (records inner → wraps → restores verbatim); survives plugin updates via a stable wrapper copy.

## Stage 4 — Interactive /unguard
- [unguard-interactive](stage-4/unguard-interactive.md) — bare `/unguard` shows the state then configures via AskUserQuestion (action + scope); with arguments unchanged; command-markdown-only change, v0.3.0.

## Stage 5 — Codex CLI compatibility (investigation + handoff)
- [codex-compatibility](stage-5/codex-compatibility.md) — measured against Codex CLI 0.144.3: the plugin **installs cleanly and protects nothing** (matcher `Bash` vs Codex's `shell`/`exec`, command not in `tool_input.command`, hooks silently skipped without trust). No code changed; README now warns, and the doc carries the evidence, repro steps, open question, and the work list for real support.
