## ADDED Requirements

### Requirement: A local smoke build labels the image with the project version
When `bin/smoke-image` builds the image itself, it SHALL pass the version from `mix.exs` as the image version. It SHALL stop with an error when it cannot find that version, rather than build an image with an empty version label.

#### Scenario: The version label is set on a local build
- **WHEN** `bin/smoke-image` runs without `SKIP_BUILD`
- **THEN** the image label `org.opencontainers.image.version` equals the `@version` in `mix.exs`

#### Scenario: A missing version stops the build
- **WHEN** the script cannot find a version in `mix.exs`
- **THEN** it stops before `docker build`, and the error names `mix.exs`
