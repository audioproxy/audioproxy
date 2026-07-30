## 1. CI workflow

- [ ] 1.1 `.github/workflows/ci.yml`: triggers (push main, PR), `test` job — checkout, setup-beam via `.tool-versions`, deps/_build cache, `mix deps.get`, `mix format --check-formatted`, `mix compile --warnings-as-errors`, `mix test`
- [ ] 1.2 `test-ffmpeg` job scaffold: ffmpeg install + `mix test --only ffmpeg` (no-op green until tagged tests exist)
- [ ] 1.3 Verify pin single-sourcing: bump toolchain in a scratch branch, confirm CI picks it up without workflow edits

## 2. Dependabot

- [ ] 2.1 `.github/dependabot.yml`: `mix` weekly (minor+patch grouped, majors individual) + `github-actions` weekly
- [ ] 2.2 Validate config (dependabot config parses; first update PRs arrive and are CI-gated)

## 3. Verification

- [ ] 3.1 Red-path checks on scratch branches: failing test → red, unformatted file → red at format step, warning-producing compile → red; green branch → green
- [ ] 3.2 Enable branch protection requiring the CI check on main (manual repo setting; record in README)

## 4. Docs

- [ ] 4.1 Update README: CI badge, what the pipeline enforces, Dependabot cadence, branch-protection note
