## ADDED Requirements

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
