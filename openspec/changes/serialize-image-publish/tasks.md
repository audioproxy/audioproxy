## 1. Serialize publishing

- [x] 1.1 `concurrency: { group: publish-${{ github.ref }}, cancel-in-progress: false }` on `publish`, and on no other job. It went on all four publish-side jobs first; the adversarial review's root cause showed that a second member of the group lets a run evict a newer run's queued `meta`, so exclusivity is part of the fix.
- [x] 1.2 Every other job left ungrouped — verification and the rest of the publish half alike — with a block comment giving the pending-eviction reason rather than only the wall-clock one

## 2. Verification

- [x] 2.1 No automated verification, decided rather than defaulted. The planned
  live experiment is not runnable — `meta`'s `if:` gates the publish half to
  `main` and `v*` tags, so a scratch branch never publishes and a pair of scratch
  `v*` tags would push real image tags and attempt `mix hex.publish`. A drift
  guard over `ci.yml` was built and then removed: it could assert that four lines
  of YAML are present, never that the platform schedules them as described, and a
  regex parser over the workflow is more upkeep than the property is worth. The
  constraint is carried by the block comment and `docs/development.md` instead.
  What the guard *did* earn is two fixes to the pre-existing parser in
  `test/required_checks_test.exs`, which are kept.

## 3. Docs

- [x] 3.1 `docs/development.md`: which half of the workflow is serialized, and why `cancel-in-progress` is `false` here where most workflows want `true`
