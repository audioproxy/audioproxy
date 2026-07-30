## Why

There is no code yet — only the API design (`docs/audio-proxy-api-v1.md`). Every other slice needs a running OTP application, a config layer, a test harness, and the per-slice worktree/devcontainer workflow to build on.

## What Changes

- Create the Mix project (app name: `audio_proxy`, working title) with a supervision tree.
- Add Plug + Bandit as the only runtime dependencies; StreamData as a test dependency.
- Implement an `AP_`-prefixed env-var config module (per API doc §6) with typed parsing, defaults, and validation at boot.
- Stand up a minimal Bandit listener with a router serving `GET /health` (unsigned, per API doc §2).
- Set up the dev workflow from CLAUDE.md: mise toolchain pin, worktrunk (`wt`) worktree config with per-branch hashed ports, devcontainer (Elixir + ffmpeg) with `bin/agent-*` binstubs.
- CI-ready test setup: `mix test` green, formatter configured.

## Capabilities

### New Capabilities

- `app-runtime`: Application boot, supervision tree, HTTP listener, `/health` endpoint, and environment-variable configuration.

### Modified Capabilities

<!-- none — greenfield -->

## Impact

- New files: `mix.exs`, `lib/audio_proxy/{application,config,router}.ex`, `test/`, `.devcontainer/`, `.config/wt.toml`, `bin/agent-*`, `mise.toml`.
- Dependencies added: `plug`, `bandit`, `stream_data` (test only).
- Every subsequent slice depends on this one and is developed on its own worktree/devcontainer pair.
