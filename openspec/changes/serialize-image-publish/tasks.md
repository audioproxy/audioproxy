## 1. Serialize publishing

- [x] 1.1 `concurrency: { group: publish-${{ github.ref }}, cancel-in-progress: false }` on `meta`, `image-build`, `publish` and `verify-published`
- [x] 1.2 Verification jobs left ungrouped, with a comment saying why they are exempt

## 2. Verification

- [x] 2.1 A drift guard, `test/publish_concurrency_test.exs`: derive the publish-side jobs structurally (a job that never runs for a pull request) and assert each carries the ref-keyed group with `cancel-in-progress: false`, and that no pull-request job carries one. The originally planned live experiment is not runnable — `meta`'s `if:` gates the publish half to `main` and `v*` tags, so a scratch branch never publishes and has no moving tag to inspect, while a pair of scratch `v*` tags would push real image tags and attempt `mix hex.publish`. Verified by mutation: dropping the group, flipping `cancel-in-progress` to `true`, dropping `github.ref` from the key, and grouping a verification job each turn the suite red.

## 3. Docs

- [x] 3.1 `docs/development.md`: which half of the workflow is serialized, and why `cancel-in-progress` is `false` here where most workflows want `true`
