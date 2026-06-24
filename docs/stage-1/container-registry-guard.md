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

- `push` — incl. `image push`, `manifest push`, compose `push`, and buildx `--push`
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
  like `image`/`manifest`/`compose`) the verb `push|login|logout`. The op is held to
  the same command segment via `[^;|&]*`; the trailing boundary `[[:space:];|&)]|$`
  lets a terminal verb match even when a separator or `)` follows it.
- `container_pushflag_re` — the buildx `--push` flag, matched separately since it is a
  flag, not a subcommand.
- Newlines/tabs are flattened to spaces (`scan`) so a line-continued command (e.g.
  multi-line `docker buildx build … --push`) is still seen on one line.

Detection biases toward over-protection (a stray `echo push` arg may prompt) because
the cardinal rule is **never under-protect**.

### Known limitations (accepted, documented)
Consistent with the pre-existing `remote_re`, the guard does not see into nested
shells (`bash -c "docker push …"`), backtick/`$()` strings, or absolute-path
invocations (`/usr/bin/docker push`). Hardening those would have to be done uniformly
across the whole hook (a separate change), not just for container ops.

## Code locations
- `scripts/guard-remote-ops.sh:27-49` — `scan` normalization + `container_re` /
  `container_pushflag_re` + `is_container` detection
- `scripts/guard-remote-ops.sh:60-61` — container ops forced to **write** class
- `scripts/guard-remote-ops.sh:77-85` — CLI-name extraction + "Container registry
  operation" reason label
- `tests/test-guard-remote-ops.sh` — 43 behavior tests (guarded ops, pass-through,
  separators, multi-line, compose v1, bypass-flag interaction, regression)
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
- Regression tests added for every fix; full suite green (43/43).

## Retrospective
The subcommand-aware approach kept local docker noise-free while closing the push gap.
The adversarial review pass earned its keep: codex caught a genuine silent-bypass and
antigravity caught two realistic misses that the happy-path tests didn't. Carry
forward: when a matcher needs two tokens on one line, normalize newlines up front.
