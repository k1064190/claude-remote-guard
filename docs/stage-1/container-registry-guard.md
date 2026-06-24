# Stage 1 — Guard container-registry push/login

## Why
The guard hook only triggered on a fixed CLI whitelist (`gcloud`, `gsutil`, `bq`,
`aws`, `az`, `kubectl`, `ssh`, `scp`, `terraform`). `docker push` to a registry was
not in that list, so an image was pushed without the approval prompt — the exact gap
Doctor Cho hit. Registry pushes reach remote infrastructure and must be guarded too.

## What
`docker` / `podman` / `nerdctl` (and the hyphenated `docker-compose` / `podman-compose`
v1 binaries) are now guarded, but **only for registry-bound operations**, classified
**write**:

- `push` / `publish` — incl. `image push`, `manifest push`, compose `push`/`publish`
- buildx registry exporters — the `--push` shorthand and its `--output type=registry`
  / `--output=type=image,…,push=true` / `-o type=registry` equivalents
- `login` / `logout`

Left untouched (pass silently, per Doctor Cho's scoping): `pull`, `search`, and all
local work (`build`, `run`, `ps`, `images`, `logs`, …). Out of scope by decision:
`git push` and package publishing (helm/npm/twine).

The `/unguard write` bypass governs these the same as any other write-class op;
`/unguard read` alone does not.

## How
Subcommand-aware matching (unlike the CLI-only `remote_re`), so local docker stays
prompt-free:

- `container_re` — CLI in command position, then (optionally past intermediate words
  like `image`/`manifest`/`compose`) the verb `push|publish|login|logout`. The op is
  held to the same command segment via `[^;|&]*`; the trailing boundary
  `[[:space:];|&)]|$` lets a terminal verb match even when a separator or `)` follows.
- `container_pushflag_re` / `container_exporter_re` — buildx pushes via the `--push`
  shorthand or its exporter equivalents (`type=registry`, `push=true`), matched
  separately since they are flags, not subcommands.
- `scan` folds bash line continuations (backslash-newline) and flattens newlines/tabs
  to spaces, so a multi-line command (e.g. `docker buildx build … --push` split across
  lines) is seen on one line.

Detection biases toward over-protection (a stray `echo push` arg may prompt) because
the cardinal rule is **never under-protect**.

### Known limitations (accepted, documented)
Consistent with the pre-existing `remote_re`, the guard does not see into nested
shells (`bash -c "docker push …"`), backtick/`$()` strings, or absolute-path
invocations (`/usr/bin/docker push`). Hardening those would have to be done uniformly
across the whole hook (a separate change), not just for container ops.

## Code locations
- `scripts/guard-remote-ops.sh:27-55` — `scan` normalization + `container_re` /
  `container_pushflag_re` / `container_exporter_re` + `is_container` detection
- `scripts/guard-remote-ops.sh:66-67` — container ops forced to **write** class
- `scripts/guard-remote-ops.sh:83-87` — CLI-name extraction + "Container registry
  operation" reason label
- `tests/test-guard-remote-ops.sh` — 51 behavior tests (guarded ops, pass-through,
  separators, multi-line, compose v1, buildx exporters, compose publish, bypass-flag
  interaction, regression)
- `README.md`, `.claude-plugin/plugin.json` — doc/description aligned

## Review loop
- **code-reviewer-pro subagent:** 0 critical / 0 warning / 2 doc-only suggestions.
  No code change required.
- **codex (gpt-5.5, high):** found a real **critical under-protection** — a verb that
  is the last token followed directly by `;`/`&`/`|`/`)` (no space) was missed
  (`docker compose push;…`, `docker logout&&…`, `(docker login)`). **Fixed** by widening
  the trailing boundary. Pushed back on its quoted-separator and `run … push`
  false-positive notes (negligible / accepted over-protection).
- **antigravity (Gemini 3.1 Pro High):** found two realistic in-scope misses —
  **multi-line** commands and the **`docker-compose`** v1 binary. **Both fixed** (`scan`
  flatten + alternation). Pushed back on absolute-path / `bash -c` / printf-newline
  notes (pre-existing whole-hook boundary; target platform is GNU grep). Confirmed the
  classification/bypass logic is correct.
- **Codex GitHub bot (PR #1, codex-pr-review loop):** three more under-protections,
  all **fixed** — (P1) buildx exporter pushes (`--output type=registry` / `push=true`)
  that the `--push`-only matcher missed; (P2) a `docker\<newline>push` continuation
  where the backslash stuck to the CLI and broke the match (the `scan` now folds
  continuations the way the shell does); (P2) `docker compose publish` as a registry
  write (added `publish`).
- Regression tests added for every fix; full suite green (51/51).

## Retrospective
The subcommand-aware approach kept local docker noise-free while closing the push gap.
The adversarial review pass earned its keep: the three review passes (local + two
subagents) plus the Codex GitHub bot each caught genuine silent-bypasses that the
happy-path tests didn't — registry writes have many spellings (`--push`, exporter
flags, `compose publish`). Carry forward: enumerate every spelling of a remote-write
verb, and when a matcher needs two tokens on one line, fold continuations up front.
