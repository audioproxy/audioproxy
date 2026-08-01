## 1. Project skeleton

- [x] 1.1 `mix new audio_proxy --sup` layout committed at repo root; `.formatter.exs`, `.gitignore`
- [x] 1.2 Pin toolchain with mise: `mise.toml` (or `.tool-versions`) with a matching Elixir/OTP pair — Elixir ≥ 1.20 (built-in gradual type checking is the project's type gate, per CLAUDE.md conventions); note in README
- [x] 1.3 Add deps: `plug`, `bandit`; test-only: `stream_data`
- [x] 1.4 Supervision tree starting Bandit with `AudioProxy.Router`; listener port from `PORT` (worktree workflow) falling back to default

## 2. Worktree + devcontainer workflow

- [x] 2.1 `.devcontainer/devcontainer.json`: Elixir/OTP + ffmpeg/ffprobe image, `postCreateCommand: bin/agent-setup`
- [x] 2.2 Binstubs: `bin/agent-setup` (deps.get + compile), `bin/agent-server` (boot on `PORT`), `bin/agent-cleanup` (no per-branch state to drop, so it only removes the worktree's container), plus `bin/agent-exec` (host → container command runner). All four branch on `DEVCONTAINER` so they work on both sides.
- [x] 2.3 `.config/wt.toml`: post-create/post-start/pre-remove/post-remove hooks with `{{ branch | hash_port }}` port scheme (adapted from an existing agentic-worktree pattern)
- [x] 2.4 `.claude/settings.json` permissions for `git worktree`, `wt`, `bin/agent-*`, `devcontainer`
- [x] 2.5 Smoke-verify: `wt start` on a scratch branch boots the app on its hashed port; document in README

## 3. Config layer

- [x] 3.1 `AudioProxy.Config`: parse all §6 vars (`AP_KEY`, `AP_SALT`, `AP_ALLOW_INSECURE`, `AP_SOURCE_ALLOWLIST`, `AP_VARIANT_BUCKET`, `AP_MAX_CONCURRENCY`, `AP_QUEUE_SIZE`, `AP_MAX_SRC_BYTES`, `AP_RENDER_TIMEOUT`, `AP_SERVE_MODE`) with types + defaults
- [x] 3.2 Boot-time validation: hex-decode key/salt, enum check for serve mode, positive-integer checks; raise with the var name on failure
- [x] 3.3 Test helper for per-test config overrides
- [x] 3.4 Tests: defaults, typed parsing, each validation failure path (asserting error mentions the var)

## 4. HTTP skeleton

- [x] 4.1 `AudioProxy.Router` with `GET /health` returning 200 JSON; 404 JSON fallback
- [x] 4.2 Plug.Test coverage: `/health` 200, unknown path 404, no signature required for `/health`

## 5. Verification & docs

- [x] 5.1 `mix test` and `mix format --check-formatted` pass; document both as the CI gate (and enforce them in `.github/workflows/ci.yml`, which also compiles with `--warnings-as-errors`)
- [x] 5.2 Update README: project intro, toolchain (mise, Elixir ≥ 1.20 typing rationale), worktree/devcontainer workflow (`wt start`), config vars, test commands
