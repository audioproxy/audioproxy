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

### Requirement: Releases publish the hex package
A `vX.Y.Z` release SHALL publish `audio_proxy X.Y.Z` to hex.pm (with docs to hexdocs.pm), gated behind the same smoke suite as the image push, so the image and the package of one version are always the same code.

#### Scenario: Tag ships both artifacts
- **WHEN** a release tag passes CI through smoke
- **THEN** the GHCR image and the hex package for that version both exist, built from the same commit

#### Scenario: Red smoke blocks the package
- **WHEN** the smoke suite fails on a tag
- **THEN** nothing is published to hex

### Requirement: The package is licensed and curated
The published package SHALL declare Apache-2.0 with the LICENSE file included, and its tarball SHALL contain only runtime-relevant files — no `openspec/`, `test/`, `examples/`, `Dockerfile`, or CI configuration — enforced by a CI content check.

#### Scenario: Tarball contents pinned
- **WHEN** the tarball-content check runs against `mix hex.build` output
- **THEN** it fails if an excluded path appears or the LICENSE is missing

### Requirement: The embedding contract is documented
The package documentation SHALL state that starting the application boots the HTTP listener and validates `AP_*` configuration from the environment — the intended contract for wrapper releases.

#### Scenario: Hexdocs states the boot behavior
- **WHEN** the package docs are published
- **THEN** the front page documents listener boot and env-driven config validation for embedders

### Requirement: Published tags are multi-arch manifests
Every published tag SHALL be a manifest list containing linux/amd64 and linux/arm64 images, such that `docker pull` on either architecture receives a native image.

#### Scenario: Manifest contains both architectures
- **WHEN** a published tag's manifest is inspected
- **THEN** it lists linux/amd64 and linux/arm64 entries

#### Scenario: Native pull on arm64
- **WHEN** the image is pulled and run on an arm64 host
- **THEN** the container runs natively (no emulation) and reports an arm64 ffmpeg

### Requirement: Each architecture is verified natively
The container smoke suite and the ffmpeg version assertion SHALL run on native runners for every published architecture; an architecture that fails smoke SHALL block the whole publish (no partial manifests).

#### Scenario: Per-arch smoke
- **WHEN** CI runs the image jobs
- **THEN** the smoke suite executes on a native runner per architecture, and both must pass before any manifest is pushed

#### Scenario: One arch fails
- **WHEN** the arm64 smoke fails while amd64 passes
- **THEN** nothing is published for that ref

