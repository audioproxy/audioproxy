## ADDED Requirements

### Requirement: Every push and pull request is verified
The repository SHALL run a CI workflow on every push to main and every pull request that fails when formatting, compilation (warnings as errors), or any test fails.

#### Scenario: Failing test blocks
- **WHEN** a branch with a failing test opens a PR
- **THEN** the CI check reports failure

#### Scenario: Formatting enforced
- **WHEN** a branch contains unformatted code
- **THEN** the CI check reports failure at the format step

#### Scenario: Green branch passes
- **WHEN** a branch passes format, compile, and test locally
- **THEN** the CI check reports success

### Requirement: CI toolchain matches the local pin
The workflow SHALL derive its Elixir/OTP versions from the repository's toolchain pin file (single source of truth), not from duplicated version strings in the workflow.

#### Scenario: Pin bump propagates
- **WHEN** the toolchain pin file changes the Elixir version
- **THEN** the next CI run uses that version with no workflow edit

### Requirement: Tagged suites run with their dependencies present
The workflow SHALL run the default (untagged) suite without external binaries, and SHALL run `:ffmpeg`-tagged tests in a job with ffmpeg installed once such tests exist.

#### Scenario: Unit suite needs no ffmpeg
- **WHEN** the default test job runs
- **THEN** it passes on a runner without ffmpeg installed

#### Scenario: ffmpeg suite isolated
- **WHEN** the ffmpeg job runs
- **THEN** ffmpeg is present and only tagged tests execute there

### Requirement: Dependencies stay current automatically
The repository SHALL receive automated update PRs for Hex dependencies and GitHub Actions versions on a weekly schedule, with minor and patch updates grouped.

#### Scenario: Outdated dependency
- **WHEN** a dependency releases a new version
- **THEN** a Dependabot PR appears within the weekly cycle and is itself verified by CI
