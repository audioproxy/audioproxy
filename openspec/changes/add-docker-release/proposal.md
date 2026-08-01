## Why

This slice is the MVP milestone: it lands immediately after the render endpoint, making the first shippable version of the API — render a variant, streamed, fully signed — deployable as the single Docker container CLAUDE.md prescribes (multi-stage build, `mix release` with bundled ERTS, ffmpeg from the runtime image). Running without `AP_VARIANT_BUCKET` (always render, no cache) is documented v1 behavior, so nothing later is required to ship. It also pins the ffmpeg version the argv contract is tested against, decides where images live and how they are versioned, and adds the image-verification jobs to the CI pipeline that later slices (variant cache, info, peaks, metrics) build on.

## What Changes

- Multi-stage `Dockerfile`: build stage (hexpm/elixir, deps + compile + release), runtime stage (alpine + `apk add ffmpeg`), non-root user, tini/proper PID-1 signal handling.
- `mix release` configuration (runtime.exs reads `AP_*` env at boot).
- Container healthcheck hitting `/health`.
- CI extension: image-build + container-smoke jobs added to the existing `ci.yml` (from `add-ci-pipeline`), gated behind the test jobs — smoke covers health and an insecure-mode render of a generated fixture from a mounted volume.
- **Publishing**: images live on GHCR (`ghcr.io/audioproxy/audioproxy`). A publish job (gated `needs: smoke`) pushes `:X.Y.Z`/`:X.Y`/`:latest` on `vX.Y.Z` git tags, and `:edge` + immutable `:sha-<short>` on every push to `main`.
- **Versioning**: SemVer where the public API is the URL contract — minor for new options/formats, major for anything changing existing URL semantics *or cache keys* (a cache-key change invalidates every cached variant). `mix.exs` version kept in sync with the tag by a CI assertion; OCI provenance labels baked into the image.
- Pin and record the ffmpeg major version; run the `@tag :ffmpeg` integration suite against the *runtime image's* ffmpeg in CI (closing the apt-vs-alpine ffmpeg gap the CI slice accepted temporarily).

## Capabilities

### New Capabilities

- `deployment`: Container packaging, release configuration, image verification, publishing, and versioning.

### Modified Capabilities

- `ci-pipeline`: The workflow SHALL additionally build the image, run the container smoke suite on every change, and publish per the tag/branch rules (new jobs, `needs: test`/`needs: smoke`).

## Impact

- New: `Dockerfile`, `.dockerignore`, `rel/` + `config/runtime.exs`.
- Modified: `.github/workflows/ci.yml` (image + smoke + publish jobs).
- Depends on: `add-render-endpoint` (the MVP surface it packages and smoke-tests), `add-ci-pipeline` (the workflow it extends).
- Later slices (`add-variant-cache`, `add-info-endpoint`, `add-peaks-format`, `add-metrics-endpoint`) extend the shipped image and reuse this CI harness; none of them block shipping. Multi-arch (arm64) is deliberately out of scope — `add-multi-arch-images`.
