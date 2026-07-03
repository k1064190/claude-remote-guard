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
- buildx registry exporters / cache writes — the `--push` shorthand and the
  `type=registry` / `push=true` forms on `--output`/`-o`/`--cache-to` (a read-only
  `--cache-from type=registry` import is deliberately not guarded)
- `buildx imagetools create` — publishing a (multi-arch) manifest to a registry
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
  `[[:space:];|&)<>]|$` lets a terminal verb match even when a separator, `)`, or a
  redirection (`<` `>`) follows.
- `container_pushflag_re` — the buildx `--push` shorthand (`--push`, `--push=true|1`,
  but not `--push=false`), a flag, not a subcommand.
- `container_exporter_re` — registry exporter / cache-write forms (`type=registry`,
  `push=true`) tied to `--output`/`-o`/`--cache-to`, so a read-only `--cache-from
  type=registry` cache import is not misclassified as a write.
- `container_imagetools_re` — `buildx imagetools create` (manifest publish).
- `scan` folds bash line continuations (backslash-newline) the way the shell does,
  turns tabs into spaces, and turns other newlines into `;` so they act as the command
  separators bash treats them as — keeping a multi-line `docker buildx build … --push`
  matched while a local `docker build .` on its own line stays quiet.

Detection biases toward over-protection (a stray `echo push` arg may prompt) because
the cardinal rule is **never under-protect**.

### Known limitations (accepted, documented)
Consistent with the pre-existing `remote_re`, the guard does not see into nested
shells (`bash -c "docker push …"`), backtick/`$()` strings, quoted shell
metacharacters (a `;`/`|`/`&` inside a quoted arg before the verb), or absolute-path
invocations (`/usr/bin/docker push`). These would need quote/shell-aware parsing done
uniformly across the whole hook (a separate change), not just for container ops.

## Code locations
- `scripts/guard-remote-ops.sh:27-60` — `scan` normalization + `container_re` /
  `container_pushflag_re` / `container_exporter_re` / `container_imagetools_re` +
  `is_container` detection
- `scripts/guard-remote-ops.sh:72` — container ops forced to **write** class
- `scripts/guard-remote-ops.sh:88-91` — CLI-name extraction + "Container registry
  operation" reason label
- `tests/test-guard-remote-ops.sh` — 61 behavior tests (guarded ops, pass-through,
  separators, multi-line, compose v1/publish, buildx exporters/imagetools, redirections,
  cache-from exclusion, bypass-flag interaction, regression)
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
- **Codex GitHub bot (PR #1, round 1):** three under-protections, all **fixed** — (P1)
  buildx exporter pushes (`--output type=registry` / `push=true`) the `--push`-only
  matcher missed; (P2) a `docker\<newline>push` continuation where the backslash stuck
  to the CLI; (P2) `docker compose publish` (added `publish`).
- **Codex GitHub bot (PR #1, round 2):** six more, **five fixed** — (P1) redirections
  (`docker push>log`) now treated as token boundaries; (P2) `buildx imagetools create`
  manifest publish now guarded; (P2) the exporter matcher tied to `--output`/`-o`/
  `--cache-to` so a read-only `--cache-from type=registry` is no longer flagged; (P3)
  newlines kept as command separators; (P3) `--push=false` no longer prompts. Pushed
  back on (P2) quoted-shell-metacharacter parsing — a whole-hook heuristic limitation,
  now documented.
- Regression tests added for every fix; full suite green (61/61).

## Retrospective
The subcommand-aware approach kept local docker noise-free while closing the push gap.
The adversarial review pass earned its keep: the three review passes (local + two
subagents) plus the Codex GitHub bot each caught genuine silent-bypasses that the
happy-path tests didn't — registry writes have many spellings (`--push`, exporter
flags, `compose publish`). Carry forward: enumerate every spelling of a remote-write
verb, and when a matcher needs two tokens on one line, fold continuations up front.
