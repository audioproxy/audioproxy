# deployment Specification

## Purpose
TBD - created by archiving change add-docker-release. Update Purpose after archive.
## Requirements
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

### Requirement: Images are published to GHCR per the tag rules
The system SHALL publish images to `ghcr.io/audioproxy/audioproxy`: a `vX.Y.Z` git tag publishes `:X.Y.Z`, `:X.Y`, and `:latest`; a push to `main` publishes `:edge` and an immutable `:sha-<short>`; publishing SHALL be gated on the smoke suite passing.

#### Scenario: Release tag publishes version tags
- **WHEN** a `vX.Y.Z` tag is pushed and CI is green through smoke
- **THEN** `:X.Y.Z`, `:X.Y`, and `:latest` are pullable from GHCR and boot

#### Scenario: Main publishes edge and sha
- **WHEN** a commit lands on `main` with CI green
- **THEN** `:edge` and `:sha-<short>` for that commit are pullable

#### Scenario: Red smoke blocks publishing
- **WHEN** the smoke suite fails
- **THEN** no image is pushed for that ref

### Requirement: Version provenance
The published image SHALL carry OCI labels (`org.opencontainers.image.source`, `.revision`, `.version`), and a release SHALL fail when the `mix.exs` version does not equal the git tag.

#### Scenario: Labels present
- **WHEN** a published image is inspected
- **THEN** source, revision, and version labels identify the repo, commit, and version

#### Scenario: Tag/version mismatch fails
- **WHEN** a `v1.2.0` tag is pushed while `mix.exs` says `1.1.0`
- **THEN** the publish job fails without pushing

### Requirement: Distributed images carry license notices and corresponding source
The published image SHALL include the Debian copyright notices for its packages and a source manifest (`/usr/share/audioproxy/SOURCES.txt`) listing every installed package at its exact version with a resolvable `snapshot.debian.org` source URL; the README SHALL state the compliance posture and the offer.

#### Scenario: Notices present
- **WHEN** the built image is inspected
- **THEN** `/usr/share/doc/ffmpeg/copyright` (and peers) exist — image slimming has not stripped them

#### Scenario: Manifest resolves
- **WHEN** the CI compliance check runs
- **THEN** the manifest exists in the image and spot-checked entries resolve to fetchable sources at the pinned versions

#### Scenario: Manifest matches the image
- **WHEN** the manifest is compared against `dpkg -l` in the same image
- **THEN** every installed package appears at its installed version

