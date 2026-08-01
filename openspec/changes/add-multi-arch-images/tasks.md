## 1. Build & publish

- [ ] 1.1 Arch matrix for the image jobs in `ci.yml`: amd64 + arm64 on native runners, each producing a digest artifact
- [ ] 1.2 Publish job: stitch digests into one manifest list per tag (`docker buildx imagetools create`), all existing tags (`:X.Y.Z`, `:X.Y`, `:latest`, `:edge`, `:sha-<short>`)
- [ ] 1.3 All-or-nothing gate: both arch smokes green before any manifest push

## 2. Verification

- [ ] 2.1 Smoke suite (existing Ruby script) runs per arch on its native runner; ffmpeg major-version assertion per arch
- [ ] 2.2 Manifest test: published tag inspected (`imagetools inspect`) lists both platforms; pull-and-boot check on the arm64 runner
- [ ] 2.3 `VERSIONS.md`: per-arch ffmpeg record if versions differ (assert equal until they don't)

## 3. Docs

- [ ] 3.1 README: supported architectures note; `docs/development.md`: arch matrix, manifest stitch, the no-byte-equality policy and its variant-bucket implication
