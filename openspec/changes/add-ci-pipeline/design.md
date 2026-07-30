## Context

Standard Elixir CI shapes are well-trodden; the design choices are about version-pin single-sourcing, job layout for tagged suites, and keeping the workflow extensible for the jobs later slices add (image build/smoke, MinIO).

## Goals / Non-Goals

**Goals:**
- Mechanical green-tests gate; toolchain single-sourced; a workflow later slices extend rather than replace.

**Non-Goals:**
- CD/deployment (docker slice owns image concerns); release automation; coverage gates (revisit when there's enough code for the number to mean something); scripting branch-protection settings.

## Decisions

- **`erlef/setup-beam` with `version-file: .tool-versions`** — the mise pin is the single source of truth for local, devcontainer, and CI toolchains. (Scaffold slice writes `.tool-versions`-compatible pins; mise reads the same file.)
- **Two-tier caching** (`deps` + `_build` keyed on `mix.lock` + OTP/Elixir versions) — the difference between 30 s and 5 min feedback.
- **Job layout**: `test` (format, compile –warnings-as-errors, unit suite; no external binaries) and `test-ffmpeg` (apt-installed ffmpeg, `--only ffmpeg`); MinIO added later as a service container on the ffmpeg job by the S3 slice. Separate jobs keep the fast path fast and make tag discipline visible — an untagged test that needs ffmpeg fails the unit job loudly.
- **Workflow is the docker slice's extension point**: image-build/smoke land as additional jobs in `ci.yml` with `needs: test`, not a parallel workflow file — one required check to protect the branch with.
- **Dependabot grouping**: minor+patch grouped per ecosystem into one weekly PR (review noise ↓), majors individual. Actions pinned by major tag (`@v4`), not SHA — this repo's threat model doesn't warrant SHA-pinning ceremony.

## Risks / Trade-offs

- [`.tool-versions` as shared pin requires mise and setup-beam to agree on format] → both support it natively; smoke-checked the day the workflow lands.
- [Grouped Dependabot PRs can bundle a breaking minor] → CI gates every PR; a red grouped PR gets split manually — cheap and rare.
- [ffmpeg version in CI (ubuntu apt) differs from the runtime image (alpine)] → acceptable until the docker slice: its integration-against-shipped-ffmpeg job closes exactly this gap permanently.
