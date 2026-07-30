## Why

"Merge when tests are green" (the worktree workflow rule) needs an enforcer from the first feature PR onward. A GitHub Actions pipeline running the suite on every push/PR, plus Dependabot keeping Hex packages and action versions patched, makes the green-tests gate mechanical rather than honor-system. It lands immediately after the scaffold — as soon as the first tests exist.

## What Changes

- GitHub Actions workflow `ci.yml`: checkout → `erlef/setup-beam` (versions read from the mise/`.tool-versions` pin — one source of truth) → deps + `_build` cache → `mix deps.get` → `mix format --check-formatted` → `mix compile --warnings-as-errors` → `mix test`.
- A second job (activates once the port-pipeline slice lands) installing ffmpeg and running `mix test --only ffmpeg`; `:integration`-tagged (MinIO) tests run in the job matrix where services are available.
- Dependabot config: `mix` ecosystem (weekly, minor+patch grouped) and `github-actions` ecosystem (weekly).
- Branch protection expectation documented: PRs require the CI check (repo-settings step, documented not scripted).

## Capabilities

### New Capabilities

- `ci-pipeline`: Automated verification on every push/PR and automated dependency updates.

### Modified Capabilities

<!-- none — no runtime behavior -->

## Impact

- New: `.github/workflows/ci.yml`, `.github/dependabot.yml`.
- Depends on: `init-project-scaffold` (a test suite and toolchain pin to run).
- Extended by: `add-ffmpeg-port-pipeline` (ffmpeg job), `add-s3-client` (MinIO service), `add-docker-release` (image build + smoke jobs join this workflow).
