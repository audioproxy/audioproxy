## Why

`ci.yml` has no `concurrency:` key. Two pushes to `main` in quick succession run two complete pipelines, each stitching its own per-arch digests onto the moving tags, and nothing serializes them: `:edge` can end up pointing at the *older* commit if that run's `publish` job lands last. The immutable `:sha-<12>` tags are unaffected — they name their own commit — so the damage is confined to `:edge`, and to `:latest`/`:X.Y` if two release tags are ever pushed close together.

The race predates `add-multi-arch-images`, which is why it was left out of that change rather than fixed inside it. But that change widened the window materially: publishing went from one `docker build --push` step to a four-job pipeline with an artifact round-trip in the middle, so the interval during which a second run can overtake the first grew from seconds to minutes. A latent race became a reachable one, and `:edge` now genuinely moves through that pipeline on every push to `main`.

## What Changes

- A `concurrency:` group on `publish` — the one job that writes a tag — keyed by
  ref, with `cancel-in-progress: false`: a publish that has started must finish
  rather than be killed half-way through stitching a manifest list.
- **No other job joins it.** GitHub allows one *pending* job per group and
  evicts the previously pending one when another is queued, and
  `cancel-in-progress: false` protects only a job already running. A second
  grouped job therefore lets one run contend with itself — two matrix legs, or
  `meta` against `verify-published` — and the eviction can land on a *newer*
  run's `meta`, skipping that run's whole publish half and leaving the moving
  tag on the older commit. Exclusivity is part of the fix, not an economy.
- `docs/development.md` records which job is serialized, why the group stops
  there, why the cancel policy is `false` where most workflows want `true`, and
  that serialization is not ordering.

## Capabilities

### New Capabilities

<!-- none -->

### Modified Capabilities

- `deployment`: a moving tag SHALL name the most recent commit that completed publishing, not whichever pipeline happened to finish last.

## Impact

- Modified: `.github/workflows/ci.yml` (a `concurrency:` block on `publish`, and
  a block comment recording why it stops there), `docs/development.md`.
- Added: `test/publish_concurrency_test.exs`, and `test/support/workflow.ex` —
  the `ci.yml` parser lifted out of `test/required_checks_test.exs`, now that a
  second guard reads the workflow.
- Depends on: `add-multi-arch-images` (the four-job publish pipeline this
  serializes).
- Deferred: making a moving tag monotonic in commit order. Serialization
  prevents interleaving, not staleness; see `deployment` spec and
  `docs/development.md`.
- Position: OSS, small. Worth doing before the next release rather than after —
  the window is widest on a busy `main`.
