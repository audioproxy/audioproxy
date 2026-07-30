## 1. CI workflow

- [x] 1.1 `.github/workflows/ci.yml`: triggers (push main, PR), `test` job — checkout, setup-beam via `.tool-versions`, deps/_build cache, `mix deps.get`, `mix format --check-formatted`, `mix compile --warnings-as-errors`, `mix test`
- [x] 1.2 `test-ffmpeg` job scaffold: ffmpeg install + `mix test --only ffmpeg` (no-op green until tagged tests exist)
- [x] 1.3 Verify pin single-sourcing: bump toolchain in a scratch branch, confirm CI picks it up without workflow edits

## 2. Dependabot

- [x] 2.1 `.github/dependabot.yml`: `mix` weekly (minor+patch grouped, majors individual) + `github-actions` weekly
- [x] 2.2 Validate config (dependabot config parses; first update PRs arrive and are CI-gated)

## 3. Verification

- [x] 3.1 Red-path checks on scratch branches: failing test → red, unformatted file → red at format step, warning-producing compile → red; green branch → green
- [x] 3.2 Enable branch protection requiring the CI check on main (manual repo setting; record in README)

## 4. Docs

- [x] 4.1 Update README: CI badge, what the pipeline enforces, Dependabot cadence, branch-protection note

## Verification log

Recorded against real runs on PR #2 and throwaway PR #3 (closed, branch deleted).

| Task | Evidence |
|---|---|
| 1.1, green path | Run 30545729252 — both jobs success |
| 1.2 | Same run: ffmpeg 6.1.1 installed; guard logged "No :ffmpeg-tagged tests yet"; job green. Both guard branches also exercised locally against a scratch tagged test |
| 1.3 | Run 30546175345 — `.tool-versions` bumped to erlang 28.5.0.3 / elixir 1.20.1-otp-28 with a byte-identical `ci.yml`; CI reported "Using Elixir 1.20.1", erts-16.4.0.3 (baseline run reported erts-16.4.0.4) |
| 2.1, 2.2 | Config parsed and asserted against the documented schema (version 2, both ecosystems weekly, groups limited to minor+patch) |
| 3.1, failing test | Run 30545855104 — failed at step `Run mix test` |
| 3.1, unformatted | Run 30545958803 — failed at step `Run mix format --check-formatted`, before compile or test ran |
| 3.1, warning | Run 30546053635 — failed at step `Run mix compile --warnings-as-errors`, log shows the unused-variable warning |
| 3.2 | Protection applied to `main` via the API: required checks "format, compile, unit tests" and "ffmpeg-tagged tests", force-pushes and deletions disabled, `enforce_admins` off |

Caveat on 2.2: the config is validated and the required checks are in place, but
the arrival of the first real Dependabot PRs is on GitHub's weekly schedule and
could not be observed at implementation time.
