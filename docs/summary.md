# Project stages — remote-guard plugin

## Stage 1 — Guard container-registry push/login
- [container-registry-guard](stage-1/container-registry-guard.md) — docker/podman/nerdctl registry-bound ops (push/publish/login/logout, buildx exporters) now prompt; local build/run/pull stay quiet.

## Stage 2 — Timed & persistent /unguard bypasses
- [unguard-ttl-persist](stage-2/unguard-ttl-persist.md) — `/unguard <class> 30m|2h|persist` survives restarts (TTL auto-re-arms, max 24h); flag contents encode the mode; SessionStart clears only session-scoped/expired flags.
