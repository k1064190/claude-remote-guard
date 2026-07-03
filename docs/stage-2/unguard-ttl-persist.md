# /unguard timed (TTL) & persistent bypasses

**Why** — Re-running `/unguard` every session was annoying when the user knows
what they're doing; a blanket SessionStart `rm -f` reset every bypass on each
restart. The user wanted the reset itself controllable from the command, ideally
time-boxed so the guard re-arms on its own.

**What** — `/unguard <read|write|all> [30m|2h|45s|N|persist]`:

- duration → bypass survives restarts, auto-expires (max 24h; bare number = minutes);
  mid-session expiry re-arms the guard on the very next guarded command
- `persist` → survives until `/unguard off`
- no argument → unchanged session-scoped flip (100% backward compatible)
- `status` shows remaining time

**How** — The flag file *contents* encode the mode: empty = session,
digits = expiry epoch, `persist` = permanent, anything else = inactive
(never under-protects). The SessionStart hook was changed from a blanket
`rm -f` to `guard-remote-session-reset.sh`, which only clears session-scoped,
expired, or unrecognized flags. `guard-remote-ops.sh` gained `flag_active()`
which does the same expiry check per command. The `/unguard` slash command
passes all args as one word, so the toggle script re-splits `$*`.

**Code locations**

- `scripts/guard-remote-toggle.sh` — duration/persist parsing, TTL write, status with remaining time
- `scripts/guard-remote-ops.sh:83-101` — `flag_active()` expiry-aware bypass check
- `scripts/guard-remote-session-reset.sh` — new SessionStart cleanup
- `hooks/hooks.json` — SessionStart now calls the reset script
- `tests/test-guard-remote-toggle.sh` (new, 20 asserts), `tests/test-guard-remote-ops.sh` (TTL/persist flag-content cases)

**Review loop** — `code-reviewer-pro` subagent flagged a check-then-read race:
a flag deleted between `[ -f ]` and `cat` reads as `''` → wrongly "session
bypass active". Fixed in `flag_active()` and `state()` (`cat … || return
inactive`, commit c1c61a7). Dismissed: same race in the session-reset script
(outcome is still correct — file ends up deleted) and an extra-argument
usage warning (out of scope).

Codex GitHub bot (PR #2, round 1) found three real issues, all **fixed**
(commit b32de9d): (P2) an overflow-sized duration silently bypassed the 24h
cap — digit length now capped before arithmetic; (P3) leading-zero durations
parsed as octal (`010m` = 8min) — forced base 10; (P3) flipping a stale
expired flag only deleted it (needed two `/unguard`s) — flip/`all` now treat
expired/unrecognized flags as OFF. Round 2: clean ("no major issues").

**Retrospective** — Encoding the mode in flag contents kept the old empty-file
format valid, so everything stayed backward compatible with no migration.
