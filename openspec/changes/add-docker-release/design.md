## Context

CLAUDE.md fixes the shape: multi-stage, `mix release` + bundled ERTS, `apk add ffmpeg`. Remaining decisions are base images, PID 1, how CI exercises the artifact, and where the artifact lives.

## Goals / Non-Goals

**Goals:**
- Reproducible image; the tested ffmpeg == the shipped ffmpeg; every deployable image traceable to a commit and pullable by exact version.

**Non-Goals:**
- Orchestration manifests (k8s/compose beyond CI), multi-arch builds (`add-multi-arch-images`), image signing/attestation (revisit if the project grows an audience), Docker Hub (possible mirror later; GHCR is the home).

## Decisions

- **Build stage `hexpm/elixir:<ver>-erlang-<ver>-alpine-<ver>`** (exact tags mirror `.tool-versions`); runtime stage plain `alpine:<ver>` with `apk add --no-cache ffmpeg` — ffmpeg version pinned by the alpine minor, recorded in a repo `VERSIONS.md` and asserted by a CI step (`ffmpeg -version` grep).
- **PID 1 = tini** (`apk add tini`, `ENTRYPOINT ["/sbin/tini","--"]`): the release's beam handles SIGTERM, tini reaps any orphaned-zombie edge cases — belt and braces for a subprocess-heavy app.
- **`config/runtime.exs` is the only config entry point** — same `AudioProxy.Config` boot validation runs in release and dev; container dies loudly on bad config.
- **Healthcheck** via `wget -qO- localhost:$PORT/health` (busybox wget, no curl needed).
- **CI smoke script in Ruby** (user convention): build image → run with `AP_ALLOW_INSECURE=true` and a mounted fixture volume (`AP_LOCAL_ROOT=/fixtures` — the MVP source type; no fake-S3 sibling container needed) → assert health, render a lavfi-generated WAV to mp3, compare ffprobe-reported duration; then run `mix test --only ffmpeg` inside the build-stage image against the runtime image's ffmpeg via a shared volume — ensures argv-contract tests see the shipped binary. (S3-sourced smoke joins post-MVP with `add-s3-client`.)
- **GHCR over Docker Hub**: the repo lives on GitHub, so `GITHUB_TOKEN` auth needs no secret management, package permissions follow the repo, and public pulls are free/unmetered for OSS. Docker Hub buys discoverability at the cost of a managed token and pull-rate politics — a mirror decision for later, not a home.
- **SemVer over the URL contract**: the API a version protects is the URL grammar + response semantics + cache-key derivation. Minor = additive (new option, new format); major = any change to existing URL semantics *or to cache keys* — key derivation changes orphan every cached variant, which is breaking even though no client code changes. Patch = everything else, including ffmpeg/alpine pin bumps (the shipped encoder changes output bytes; a pulled `:X.Y` must not silently change what it renders — hence pin bumps always cut a release).
- **Tag → image mapping**: `vX.Y.Z` git tag publishes `:X.Y.Z`, `:X.Y`, `:latest`; `main` publishes `:edge` + `:sha-<12>` (immutable, one per commit — exact pinning and bisection). A CI assertion fails the release if `mix.exs` version ≠ tag.
- **OCI labels** (`org.opencontainers.image.source|revision|version`) baked in at build — provenance without a registry-specific mechanism; also what links the GHCR package to the repo.

## Risks / Trade-offs

- [Alpine/musl DNS or ffmpeg build quirks vs debian] → alpine is the CLAUDE.md decision; smoke test + integration suite against the actual image is the guardrail. Escape hatch: debian-slim runtime with the same Dockerfile structure.
- [apk ffmpeg version moves with alpine patch releases] → pin alpine minor, assert major in CI, document upgrade procedure (bump + full integration run + patch release).
- [`:latest` is mutable and someone will deploy it] → README documents `:X.Y.Z` (or `:sha-*`) as the deployment recommendation; `:latest` exists because its absence confuses more than its presence misleads.

## Migration Plan

First release is `v0.1.0` at the MVP milestone — 0.x signals the URL contract may still move; `v1.0.0` when the post-MVP slices stabilize it.
