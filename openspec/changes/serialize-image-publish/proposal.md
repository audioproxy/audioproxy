## Why

`ci.yml` has no `concurrency:` key. Two pushes to `main` in quick succession run two complete pipelines, each stitching its own per-arch digests onto the moving tags, and nothing serializes them: `:edge` can end up pointing at the *older* commit if that run's `publish` job lands last. The immutable `:sha-<12>` tags are unaffected — they name their own commit — so the damage is confined to `:edge`, and to `:latest`/`:X.Y` if two release tags are ever pushed close together.

The race predates `add-multi-arch-images`, which is why it was left out of that change rather than fixed inside it. But that change widened the window materially: publishing went from one `docker build --push` step to a four-job pipeline with an artifact round-trip in the middle, so the interval during which a second run can overtake the first grew from seconds to minutes. A latent race became a reachable one, and `:edge` now genuinely moves through that pipeline on every push to `main`.

## What Changes

- A `concurrency:` group on the publish-side jobs, keyed by ref, with `cancel-in-progress: false` — a publish that has started must finish rather than be killed half-way through stitching a manifest list.
- The verification jobs stay outside the group: they are pure functions of a commit, they hold no registry state, and serializing them would double the wall-clock cost of a busy day for no benefit.
- `docs/development.md` records which half of the workflow is serialized and why the cancel policy is `false` where most workflows want `true`.

## Capabilities

### New Capabilities

<!-- none -->

### Modified Capabilities

- `deployment`: a moving tag SHALL name the most recent commit that completed publishing, not whichever pipeline happened to finish last.

## Impact

- Modified: `.github/workflows/ci.yml` (a `concurrency:` block on `meta`, `image-build`, `publish`, `verify-published`), `docs/development.md`.
- Depends on: `add-multi-arch-images` (the four-job publish pipeline this serializes).
- Position: OSS, small. Worth doing before the next release rather than after — the window is widest on a busy `main`.
