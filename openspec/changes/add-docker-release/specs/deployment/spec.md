## ADDED Requirements

### Requirement: Single self-contained image
The system SHALL build as a multi-stage Docker image whose runtime stage contains the `mix release` (bundled ERTS), ffmpeg/ffprobe, and nothing else needed at runtime; the container SHALL run as a non-root user.

#### Scenario: Image builds and boots
- **WHEN** the image is built and run with valid `AP_*` env vars
- **THEN** the container reaches healthy (healthcheck on `/health`) within the start period

#### Scenario: ffmpeg present and pinned
- **WHEN** `ffmpeg -version` is executed in the runtime image
- **THEN** it reports the pinned major version recorded in the repo

#### Scenario: Non-root
- **WHEN** the container's main process is inspected
- **THEN** it runs as a non-root uid

### Requirement: Runtime configuration via environment
The release SHALL read all `AP_*` configuration at container start (not build time), applying the same boot validation as in dev.

#### Scenario: Config change without rebuild
- **WHEN** the same image is started with a different `AP_MAX_CONCURRENCY`
- **THEN** the new value is in effect

#### Scenario: Invalid config fails the container
- **WHEN** the container starts with a malformed `AP_KEY`
- **THEN** it exits nonzero with the validation error on stderr/stdout

### Requirement: Graceful shutdown
The container SHALL propagate SIGTERM to the release, terminate in-flight renders per supervisor shutdown (no orphaned ffmpeg), and exit within the stop grace period.

#### Scenario: SIGTERM during render
- **WHEN** the container receives SIGTERM while a render streams
- **THEN** the container exits cleanly and no ffmpeg process survives in the container's final process table

### Requirement: CI verifies the image
CI SHALL build the image on every change and run the smoke suite against the built container, including one end-to-end render, plus the ffmpeg-tagged integration tests against the image's ffmpeg.

#### Scenario: Smoke test gate
- **WHEN** CI runs on a branch
- **THEN** image build + container smoke render must pass for the pipeline to be green
