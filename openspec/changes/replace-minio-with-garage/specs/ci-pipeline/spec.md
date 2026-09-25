## ADDED Requirements

### Requirement: The store-backed suite runs against one pinned S3-compatible store
The workflow SHALL run the store-tagged tests against a real S3-compatible store that verifies signatures, started from an image pinned by digest. The devcontainer and the image smoke test SHALL start the same image with the same configuration file, so a pass at one level is a pass against the store the other levels use.

#### Scenario: The store suite runs in CI
- **WHEN** the default test job runs
- **THEN** the store is started and healthy before `mix test --include integration --include s3_store` begins, and a store that fails to start fails the job rather than skipping the suite

#### Scenario: One image, three consumers
- **WHEN** the store image or its configuration changes
- **THEN** the devcontainer, the CI test job and `bin/smoke-image` all reference the changed value, and none keeps a copy of its own

#### Scenario: The store boots from configuration alone
- **WHEN** a fresh store container starts
- **THEN** its layout, access key and region come from the mounted configuration and environment, with no init container or setup script
