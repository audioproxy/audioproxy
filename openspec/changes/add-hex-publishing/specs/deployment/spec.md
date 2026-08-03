## ADDED Requirements

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
