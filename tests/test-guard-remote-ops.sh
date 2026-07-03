#!/usr/bin/env bash
# test-guard-remote-ops.sh — behavior tests for scripts/guard-remote-ops.sh.
#
# Feeds a PreToolUse hook payload ({"tool_input":{"command": ...}}) on stdin and
# checks whether the hook asks for approval (emits permissionDecision "ask") or
# stays silent (lets normal permission handling proceed). Runs under an isolated
# HOME so the session bypass flags never leak in from the real environment.
set -u

here=$(cd "$(dirname "$0")" && pwd)
HOOK="$here/../scripts/guard-remote-ops.sh"

# Isolated HOME -> no bypass flags unless a test sets them explicitly.
TEST_HOME=$(mktemp -d)
trap 'rm -rf "$TEST_HOME"' EXIT
flag_dir="$TEST_HOME/.claude/remote-guard"

pass=0
fail=0

# run "<command>" -> echoes "prompt" if the guard asks, "pass" if it stays quiet.
run() {
  local out
  out=$(jq -n --arg c "$1" '{tool_input:{command:$c}}' | HOME="$TEST_HOME" bash "$HOOK")
  if printf '%s' "$out" | grep -q 'permissionDecision'; then echo prompt; else echo pass; fi
}

# expect <prompt|pass> "<command>" [note]
expect() {
  local want="$1" cmd="$2" got
  got=$(run "$cmd")
  if [ "$got" = "$want" ]; then
    pass=$((pass + 1))
  else
    fail=$((fail + 1))
    printf 'FAIL  want=%-6s got=%-6s  %s\n' "$want" "$got" "$cmd"
  fi
}

# classified <write|read> "<command>" — assert the guard's reason reports this class.
classified() {
  local want="$1" cmd="$2" out
  out=$(jq -n --arg c "$cmd" '{tool_input:{command:$c}}' | HOME="$TEST_HOME" bash "$HOOK")
  if printf '%s' "$out" | grep -q "classified $want"; then
    pass=$((pass + 1))
  else
    fail=$((fail + 1))
    printf 'FAIL  want class=%-6s  %s\n' "$want" "$cmd"
  fi
}

rm -rf "$flag_dir"

# --- Container registry push / auth ops are guarded (new behavior) ----------------
expect prompt 'docker push myregistry.io/app:v1'
expect prompt 'docker image push myregistry.io/app:v1'
expect prompt 'docker manifest push myregistry.io/app:v1'
expect prompt 'docker buildx build --push -t myregistry.io/app:v1 .'
expect prompt 'docker login myregistry.io'
expect prompt 'docker logout'
expect prompt 'docker compose push'
expect prompt 'docker --context prod push reg/img:tag'
expect prompt 'podman push quay.io/x/y:1'
expect prompt 'nerdctl push reg/x:1'
expect prompt 'docker build -t x . && docker push reg/x:1'

# Verb as the last token, immediately followed by a shell separator or subshell ')'
# (no trailing space) -- common for `compose push`, `login`, `logout`.
expect prompt 'docker compose push;echo done'
expect prompt 'docker logout&&echo bye'
expect prompt '(docker login)'
expect prompt 'docker buildx build -t x . --push;echo done'

# Hyphenated compose v1 binary.
expect prompt 'docker-compose push'
expect prompt 'podman-compose push web'

# Line-continued / multi-line command: CLI and verb land on different lines.
expect prompt "$(printf 'docker \\\n push reg/x:1')"
expect prompt "$(printf 'docker buildx build -t reg/x . \\\n  --push')"
# Backslash flush against the CLI name -- the shell joins it to `docker  push`.
expect prompt "$(printf 'docker\\\n  push reg/x:1')"

# buildx publishes to a registry via exporter flags, not just the --push shorthand.
expect prompt 'docker buildx build --output type=registry -t ghcr.io/acme/app .'
expect prompt 'docker buildx build --output=type=image,push=true -t x .'
expect prompt 'docker buildx build -o type=registry -t x .'

# compose publish ships images to a registry.
expect prompt 'docker compose publish ghcr.io/acme/app:latest'
expect prompt 'docker-compose publish reg/app:1'

# Redirections are token boundaries too -- the verb/flag is still the registry write.
expect prompt 'docker push>push.log'
expect prompt 'docker login<token.txt'
expect prompt 'docker buildx build --push>build.log -t ghcr.io/acme/app .'

# buildx imagetools create publishes a (multi-arch) manifest to a registry.
expect prompt 'docker buildx imagetools create -t ghcr.io/acme/app:latest a b'

# buildx exporter / cache-write forms, tied to --output / -o / --cache-to.
expect prompt 'docker buildx build --cache-to type=registry,ref=ghcr.io/acme/cache .'
expect prompt 'docker buildx build --push=true -t x .'

# Push / login / logout are all the write class.
classified write 'docker push myregistry.io/app:v1'
classified write 'docker login myregistry.io'

# --- Local / read-only container work passes through (no prompt) ------------------
expect pass 'docker pull alpine:3.19'
expect pass 'docker search nginx'
expect pass 'docker build -t local/app .'
expect pass 'docker run --rm alpine echo hi'
expect pass 'docker ps -a'
expect pass 'docker images'
expect pass 'docker logs mycontainer'
expect pass 'docker run --name pushgateway prom/pushgateway'   # 'push' as a substring
expect pass 'docker run --network login-net alpine'            # 'login' as a substring
expect pass 'docker build . && echo pushed'                    # push after a separator, not a docker op
expect pass 'docker buildx build --output type=local -t x .'   # local exporter, not a registry push
expect pass 'docker buildx build --output type=docker -t x .'  # loads into the local daemon, no push
expect pass 'docker buildx build --cache-from type=registry,ref=ghcr.io/acme/cache .'  # cache import (read)
expect pass 'docker buildx imagetools inspect ghcr.io/acme/app:latest'                 # read-only manifest read
expect pass 'docker buildx build --push=false -t local/app .'                          # push explicitly disabled
expect pass "$(printf 'docker build .\necho push')"                                    # newline = command separator

# --- Out-of-scope: git push and bare tokens are not container ops -----------------
expect pass 'git push origin main'
expect pass 'echo push'

# --- Regression: existing remote CLIs still prompt --------------------------------
expect prompt 'aws s3 ls'
expect prompt 'kubectl get pods'
expect prompt 'terraform apply'
expect prompt 'gcloud compute instances list'

# --- Regression: ordinary local commands still pass -------------------------------
expect pass 'ls -la'
expect pass 'git status'
expect pass 'cat dockerfile'        # 'docker' as a substring, not in command position

# --- Bypass flags still govern the container ops ----------------------------------
mkdir -p "$flag_dir"
: > "$flag_dir/bypass-write"
expect pass 'docker push reg/x:1'   # write bypass -> container push is silent
expect pass 'docker login reg'
rm -f "$flag_dir/bypass-write"
: > "$flag_dir/bypass-read"
expect prompt 'docker push reg/x:1' # read bypass alone does not cover write-class push
rm -f "$flag_dir/bypass-read"

# --- Timed / persistent bypass flag contents ---------------------------------------
# A flag holding a future epoch is active; a past epoch has expired (guard back on).
now=$(date +%s)
printf '%s' "$((now + 3600))" > "$flag_dir/bypass-write"
expect pass 'docker push reg/x:1'          # unexpired TTL bypass
printf '%s' "$((now - 10))" > "$flag_dir/bypass-write"
expect prompt 'docker push reg/x:1'        # expired TTL -> prompt again
test ! -f "$flag_dir/bypass-write" \
  && pass=$((pass + 1)) \
  || { fail=$((fail + 1)); echo 'FAIL  expired flag not cleaned up by hook'; }
printf 'persist' > "$flag_dir/bypass-write"
expect pass 'docker push reg/x:1'          # persistent bypass
printf 'garbage!' > "$flag_dir/bypass-write"
expect prompt 'docker push reg/x:1'        # unknown content -> guard stays on
rm -f "$flag_dir/bypass-write"
printf '%s' "$((now + 3600))" > "$flag_dir/bypass-read"
expect pass 'aws s3 ls'                    # TTL read bypass covers read class
expect prompt 'terraform apply'            # ...but not write class
rm -f "$flag_dir/bypass-read"

printf '\n%d passed, %d failed\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
