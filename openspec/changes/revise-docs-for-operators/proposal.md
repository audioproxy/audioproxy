## Why

The operator docs are written by the people who built the internals, and it shows in two ways. Examples are option-first ("here is `f:opus/br:96/t:0:30`") where a reader who has never used ffmpeg needs goal-first ("to make a 30-second preview…"). And module names leak — `AudioProxy.Source`, the source-type contract, `@high_water in AudioProxy.Ffmpeg.Render` — into pages whose readers operate the proxy and never open the codebase. The docs site now fronts these pages to exactly that audience.

## What Changes

- **The audience rule, stated and guarded**: operator docs (`sources`, `rendering`, `scaling`, `capacity`, `s3-providers`) SHALL contain no Elixir module references — enforced by a grep-shaped test, so the rule survives future edits the way every documentation rule here survives: by failing CI.
- **Relocate, don't delete**: `sources.md`'s "The source-type contract" section (and similar contributor material) moves into `development.md`, which is *for* people who open the codebase. Module-attributed constants in `capacity.md` become behavior-named ("the pipeline's high-water mark, 1 MiB") with one contributor pointer to where the constants live.
- **Goal-first examples throughout**: every example opens with what the reader wants ("a preview for a track page", "the shape speech-to-text wants") and then explains each option it used, assuming no ffmpeg knowledge. Editorial, not mechanical — the guard cannot check this, the review must.
- **CLAUDE.md's docs-shape table** gains the audience column: operator docs speak to users (goal-first, no module names); internals belong to `development.md` and `ffmpeg-arguments.md`.
- The docs site drops `ffmpeg-arguments` and `development` from its Guides (done site-side): by the doc-shape table's own tests they are "how the sausage is made" and "working on the repo" — contributor documents, linked from the site rather than hosted as user guides.

## Capabilities

### New Capabilities

- `operator-docs`: the audience contract for operator-facing documentation and its mechanical guard.

### Modified Capabilities

<!-- none -->

## Impact

- Modified: `docs/sources.md`, `docs/rendering.md`, `docs/capacity.md` (the three with leaks), `docs/development.md` (receives the contract section), CLAUDE.md, one new guard test.
- Content moves and rewrites only — no behavior, no contract, no config changes.
