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

- **The group goes on `publish` alone.** It is the only job that writes a tag,
  so it is the only shared state two runs can race over. The first draft of
  this change put the group on all four publish-side jobs and was wrong: GitHub
  permits one *pending* job per group and cancels the previously pending one
  whenever another is queued, while `cancel-in-progress: false` protects only a
  job that is already running. Four grouped jobs — two of them matrices — give a
  single run several ways to want the group at once, and the eviction lands on
  whatever is pending. With run A publishing and run B queued, A's second
  `verify-published` leg evicts B's `meta`, B never publishes, and `:edge`
  stays on A. That is this change's own bug, made deterministic. One job in the
  group means at most one pending entry per run and nothing to evict.
- **`cancel-in-progress: false`, deliberately.** The reflex is `true`, and it
  would be actively harmful: cancelling a run mid-`publish` can leave some tags
  of a release stitched and others not, which is the partial state the
  multi-arch work exists to prevent.
- **Keyed by ref, not by workflow.** `github.ref` gives one queue for `main` and
  one per release tag. A tag push and a `main` push touch disjoint tag sets and
  need not wait on each other.
- **`meta` is *not* in the group.** An earlier draft argued it should be, so
  that the version a run computes and the digests it publishes could not come
  from different points in the queue. That benefit does not exist: job outputs
  flow along `needs:` within a run, so `publish` reads its own run's `meta`
  whatever the grouping. The cost — a second pending entry — is real.

## Risks / Trade-offs

- [A slow publish delays the next one] → accepted, and the point. Publishing is
  minutes; pushes to `main` that close together are rare, and the alternative is
  a wrong `:edge`.
- [**Serialization is not ordering**] → known, and not fixed here. GitHub queues
  by arrival at the job, so a run whose build was slow can publish after a newer
  one and leave a moving tag on the older commit. The group prevents two
  publishes *interleaving*; it does not make the tag monotonic. Doing that means
  `publish` refusing to move a tag backwards, which is a separate change.
- [A future edit adds a second job to the group] → this is the regression the
  guard is aimed at, because it reads as a tightening. `test/publish_concurrency_test.exs`
  fails on any second `concurrency:` block in the workflow.
