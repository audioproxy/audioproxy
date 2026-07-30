## Context

CLAUDE.md fixes the shape: multi-stage, `mix release` + bundled ERTS, `apk add ffmpeg`. Remaining decisions are base images, PID 1, and how CI exercises the artifact.

## Goals / Non-Goals

**Goals:**
- Reproducible image; the tested ffmpeg == the shipped ffmpeg.

**Non-Goals:**
- Orchestration manifests (k8s/compose beyond CI), multi-arch builds (follow-up), image signing.

## Decisions

- **Build stage `hexpm/elixir:<ver>-erlang-<ver>-alpine-<ver>`** (exact tags mirror `mise.toml`); runtime stage plain `alpine:<ver>` with `apk add --no-cache ffmpeg` — ffmpeg version pinned by the alpine minor, recorded in a repo `VERSIONS.md` and asserted by a CI step (`ffmpeg -version` grep).
- **PID 1 = tini** (`apk add tini`, `ENTRYPOINT ["/sbin/tini","--"]`): the release's beam handles SIGTERM, tini reaps any orphaned-zombie edge cases — belt and braces for a subprocess-heavy app.
- **`config/runtime.exs` is the only config entry point** — same `AudioProxy.Config` boot validation runs in release and dev; container dies loudly on bad config.
- **Healthcheck** via `wget -qO- localhost:$PORT/health` (busybox wget, no curl needed).
- **CI smoke script in Ruby** (user convention): build image → run with `AP_ALLOW_INSECURE=true` + fake-S3 sibling container (or MinIO) → assert health, render a lavfi-generated WAV to mp3, compare ffprobe-reported duration; then run `mix test --only ffmpeg` inside the build-stage image against the runtime image's ffmpeg via a shared volume — ensures argv-contract tests see the shipped binary.

## Risks / Trade-offs

- [Alpine/musl DNS or ffmpeg build quirks vs debian] → alpine is the CLAUDE.md decision; smoke test + integration suite against the actual image is the guardrail. Escape hatch: debian-slim runtime with the same Dockerfile structure.
- [apk ffmpeg version moves with alpine patch releases] → pin alpine minor, assert major in CI, document upgrade procedure (bump + full integration run).
