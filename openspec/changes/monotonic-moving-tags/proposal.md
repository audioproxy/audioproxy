## Why

`serialize-image-publish` put a `concurrency:` group on `publish` so two
pipelines cannot interleave their writes to the moving tags. It deliberately did
not make those tags *monotonic*, and that gap is real rather than theoretical.

GitHub queues on arrival at the job, not by commit date. Run A and run B build in
parallel — different runners, different cache states, and on this workflow an
arm64 leg whose timing varies a lot — so B can reach `publish` first and A
second. The group then serializes them correctly and `:edge` ends on A, the older
commit. Nothing fails, nothing is torn, and the tag is wrong until the next push.

The window is the same one serialization was bought for, and the symptom is the
one it was bought to prevent, so leaving it undocumented in code is the residue
of that change rather than a new idea.

## What Changes

- `publish` refuses to move a moving tag backwards: before stitching, read what
  the tag currently resolves to, and skip the tags whose current image is newer
  than the commit being published.
- The comparison needs a commit ordering the job can read without a checkout of
  both commits. The image already carries an OCI revision label; whether that is
  enough, or whether a committer timestamp label has to be added first, is the
  design question and is not settled here.
- A skipped tag is a *logged, successful* outcome, not a failure: it means a
  newer image already holds it, which is the correct end state.
- `:sha-<12>` is untouched. It names its own commit and was never at risk.

## Capabilities

### New Capabilities

<!-- none -->

### Modified Capabilities

- `deployment`: a moving tag SHALL NOT move from a newer commit's image to an
  older one.

## Impact

- Modified: `.github/workflows/ci.yml` (the stitch step in `publish`), and
  whichever of `docs/development.md` describes the guarantee.
- Depends on: `serialize-image-publish` (merged), whose *One publish at a time*
  section states this gap and should be updated to state the fix instead.
- Open: how `publish` compares two commits from inside the job. Resolve in
  `design.md` before implementing.
- Position: OSS, small. Not urgent — the failure is a stale `:edge` until the
  next push, and pushes that close together are rare — but it is the last
  correctness gap in the publish path.
