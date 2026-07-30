## Why

This slice is the MVP milestone: it lands immediately after the render endpoint, making the first shippable version of the API — render a variant, streamed, fully signed — deployable as the single Docker container CLAUDE.md prescribes (multi-stage build, `mix release` with bundled ERTS, ffmpeg from the runtime image). Running without `AP_VARIANT_BUCKET` (always render, no cache) is documented v1 behavior, so nothing later is required to ship. It also pins the ffmpeg version the argv contract is tested against, and establishes the CI harness that later slices (variant cache, info, peaks, metrics) plug their integration suites into.

## What Changes

- Multi-stage `Dockerfile`: build stage (hexpm/elixir, deps + compile + release), runtime stage (alpine + `apk add ffmpeg`), non-root user, tini/proper PID-1 signal handling.
- `mix release` configuration (runtime.exs reads `AP_*` env at boot).
- Container healthcheck hitting `/health`.
- CI: build the image and run a smoke test against the container (health, insecure-mode render of a generated fixture through the fake S3).
- Pin and record the ffmpeg major version; run the `@tag :ffmpeg` integration suite against the *runtime image's* ffmpeg in CI.

## Capabilities

### New Capabilities

- `deployment`: Container packaging, release configuration, and image verification.

### Modified Capabilities

<!-- none -->

## Impact

- New: `Dockerfile`, `.dockerignore`, `rel/` + `config/runtime.exs`, CI workflow.
- Depends on: `add-render-endpoint` (the MVP surface it packages and smoke-tests).
- Later slices (`add-variant-cache`, `add-info-endpoint`, `add-peaks-format`, `add-metrics-endpoint`) extend the shipped image and reuse this CI harness; none of them block shipping.
