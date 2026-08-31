## 1. Serialize publishing

- [ ] 1.1 `concurrency: { group: publish-${{ github.ref }}, cancel-in-progress: false }` on `meta`, `image-build`, `publish` and `verify-published`
- [ ] 1.2 Verification jobs left ungrouped, with a comment saying why they are exempt

## 2. Verification

- [ ] 2.1 Two pushes to a scratch branch in quick succession: assert the second run's publish waits, and that the resulting moving tag resolves to the newer commit's digest

## 3. Docs

- [ ] 3.1 `docs/development.md`: which half of the workflow is serialized, and why `cancel-in-progress` is `false` here where most workflows want `true`
