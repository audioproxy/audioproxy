## Context

GitHub's `concurrency:` is available at workflow level and at job level. Workflow level is the wrong instrument here: it would serialize the *whole* CI run, including the six verification jobs that have no shared state and are the bulk of the wall clock.

## Goals / Non-Goals

**Goals:**
- A moving tag names the newest commit that finished publishing.

**Non-Goals:**
- Serializing verification. Those jobs read a commit and write nothing outside their own run.
- Cancelling superseded runs. Tempting — it is the usual `cancel-in-progress: true` idiom — and wrong here (see below).
- Fixing the non-atomicity of a multi-`--tag` `imagetools create`. If that call fails part-way, some tags move and others do not. Real, inherited from the single-step push, and a different problem: serialization does not address it and neither does this change.

## Decisions

- **`cancel-in-progress: false`, deliberately.** The reflex is `true`, and it would be actively harmful: cancelling a run mid-`publish` can leave some tags of a release stitched and others not, which is the partial state the multi-arch work exists to prevent. A publish that has begun must be allowed to finish; the next run then supersedes it in an orderly way.
- **Keyed by ref, not by workflow.** `github.ref` gives one queue for `main` and one per release tag. A tag push and a `main` push touch disjoint tag sets and need not wait on each other.
- **The group covers `meta` too**, cheap as it is, so that the version a run computes and the digests it publishes cannot come from different points in the queue.

## Risks / Trade-offs

- [A slow publish delays the next one] → accepted, and the point. Publishing is minutes; pushes to `main` that close together are rare, and the alternative is a wrong `:edge`.
- [Queued runs accumulate on a very busy day] → GitHub keeps only the most recent pending run per group and cancels older *pending* ones, which is the correct behaviour: superseded work that has not started is worth nothing.
