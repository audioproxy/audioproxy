## ADDED Requirements

### Requirement: CI verifies the container image
The CI workflow SHALL build the Docker image on every change and run the smoke suite against the built container — health check, one end-to-end insecure-mode render — plus the `:ffmpeg`-tagged integration tests against the runtime image's ffmpeg, as jobs gated behind the test jobs.

#### Scenario: Smoke test gate
- **WHEN** CI runs on a branch
- **THEN** image build + container smoke render must pass for the pipeline to be green

#### Scenario: Shipped ffmpeg is the tested ffmpeg
- **WHEN** the integration job runs
- **THEN** the `:ffmpeg`-tagged suite executes against the ffmpeg binary from the runtime image, and the pinned major version is asserted
