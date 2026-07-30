# ci-pipeline Specification

## Purpose
Makes "merge when tests are green" a mechanical check rather than an
honor-system rule, and keeps dependencies patched without anyone remembering to
look.

Two properties matter more than the particular steps. The toolchain is
single-sourced: CI derives its Elixir/OTP versions from the same pin file the
local shell reads, so the two cannot drift and a bump is a one-file edit.
And tag discipline is enforced by job layout rather than convention: the
default suite runs on a runner with no external binaries, so a test that
quietly depends on ffmpeg fails loudly instead of passing by accident.

One workflow file is deliberate. Later slices (the release image build, MinIO
as a service container) add jobs to it rather than parallel workflows, so there
stays exactly one set of checks to require on `main`.

## Requirements
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

