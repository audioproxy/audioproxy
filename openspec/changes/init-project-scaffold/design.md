## Context

Greenfield Elixir project. Stack is decided (CLAUDE.md): Plug + Bandit, no Phoenix, boring OTP, env-var config only.

## Goals / Non-Goals

**Goals:**
- A bootable, testable skeleton every other slice builds on.
- Config surface matching API doc §6 exactly, validated at boot.

**Non-Goals:**
- Any endpoint beyond `/health`; signing; rendering; S3. Those are later slices.

## Decisions

- **App name `audio_proxy`** — working title per CLAUDE.md open questions; renaming later is a cheap find/replace while the project is small.
- **Config as a compile-free runtime module** (`AudioProxy.Config`), reading `System.fetch_env/1` once at boot into `:persistent_term` — cheap reads on the hot path, no GenServer bottleneck, no app-env indirection. Validation errors raise during `Application.start/2` (fail fast).
- **Router is a `Plug.Router`** — the API is small and fixed; no need for anything heavier.
- **`mix format` + `mix test` as the CI gate** from day one; StreamData included now so property tests (mandated by CLAUDE.md conventions) are frictionless in every later slice.

## Risks / Trade-offs

- [`:persistent_term` makes config effectively immutable at runtime] → acceptable: 12-factor config is process-lifetime anyway; tests use a helper to swap config in an isolated way (`put_config/2` test helper writing per-test overrides).
