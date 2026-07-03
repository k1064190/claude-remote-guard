# Remote/Cloud Guard — Claude Code plugin

A safety guard for [Claude Code](https://code.claude.com). It forces an explicit
**yes/no approval prompt** before Claude runs any command that reaches a real or
remote server / cloud resource, so an agent can't silently touch your
infrastructure — even in auto / accept-edits modes.

Covered CLIs: `gcloud`, `gsutil`, `bq`, `aws`, `az`, `kubectl`, `ssh`, `scp`, `terraform`.

Container image tooling (`docker`, `podman`, `nerdctl`) is also covered, but only
for **registry-bound** operations — `push` / `publish` (incl. `image push`,
`manifest push`, compose `push`/`publish`, `buildx imagetools create`, buildx
`--push` and the `type=registry` / `push=true` forms on `--output`/`-o`/`--cache-to`)
and `login` / `logout`. Local work and read-only `pull` / `search` / `inspect` and a
`--cache-from` import pass through without a prompt.

## What it does

- A `PreToolUse` hook inspects every `Bash` command. If it invokes one of the
  CLIs above (matched only in command position, so `~/.ssh`, `bazel`, `awscli`
  don't false-trigger), Claude Code prompts you to approve or reject it.
- For `docker` / `podman` / `nerdctl` it prompts only on registry pushes and
  `login` / `logout` (all **write**), so `docker build` / `run` / `ps` and
  `docker pull` stay quiet.
- Each matched command is **classified**:
  - **read** — `list` / `describe` / `get` / `show` / `logs` / `plan` / `top` …
  - **write/dangerous** — `create` / `delete` / `update` / `apply` / `exec` /
    `ssh` / `scp` / `bq query` … and anything unrecognized (safe default).
- The `/unguard` command lets you bypass either class — for the current session
  (default), for a limited time (`30m`, `2h` — survives restarts, guard re-arms
  automatically when it expires), or until you turn it back on (`persist`).
- A `SessionStart` hook clears session-scoped and expired bypasses on every new
  session, so the guard is always back on after a restart unless you explicitly
  asked for a longer window.

## Install

```bash
claude plugin marketplace add k1064190/claude-remote-guard
claude plugin install remote-guard@cho-plugins
```

Updates: `claude plugin update remote-guard` (or auto-update on launch).

## Usage — `/unguard`

```
/unguard            # show current bypass state (with remaining time if timed)
/unguard read       # toggle the read(조회) bypass for this session
/unguard write      # toggle the write(변경·삭제·ssh) bypass for this session
/unguard all        # toggle both for this session
/unguard write 30m  # write bypass for 30 minutes — survives restarts, then re-arms
/unguard all 2h     # both bypasses for 2 hours (also: 45s; bare number = minutes; max 24h)
/unguard read persist   # read bypass until explicitly turned off
/unguard off        # clear both (re-enable the guard now)
```

`/unguard` is explicit-invocation only (`disable-model-invocation`), so the model
can't turn the guard off on its own — only you can.

## Behavior notes

- The read/write split is a heuristic. When in doubt a command is treated as
  **write** (the protected class), so the guard never under-protects.
- `ssh` and `scp` are always **write** (a remote shell / file transfer can't be
  classified), and `bq query` is **write** (it can run DML/DDL).
- Bypass flags live at `~/.claude/remote-guard/`. `SessionStart` fires on
  startup / resume / clear / compact, each of which resets session-scoped
  bypasses. Timed bypasses expire on their own (checked on every guarded
  command, so mid-session expiry re-arms the guard immediately); `persist`
  bypasses survive until `/unguard off`.

## Optional: status-line indicator

This plugin does not modify your status line (it can't merge with a custom one).
If you want a visible indicator, add this to your `statusLine` script:

```sh
gr=""; [ -f "$HOME/.claude/remote-guard/bypass-read" ]  && gr="R"
gw=""; [ -f "$HOME/.claude/remote-guard/bypass-write" ] && gw="W"
if [ -n "$gr$gw" ]; then printf '  🔓guard:%s' "$gr$gw"; else printf '  🔒guard'; fi
```

## Uninstall

```bash
claude plugin uninstall remote-guard
```

## License

MIT — see [LICENSE](LICENSE).
