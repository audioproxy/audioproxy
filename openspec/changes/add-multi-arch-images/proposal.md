## Why

`add-docker-release` publishes amd64-only. arm64 is no longer exotic: Graviton/Ampere instances are often the cheapest CPU-per-render, and Apple Silicon machines run the image locally through emulation (slow, and QEMU + BEAM JIT is historically flaky). Publishing a multi-arch manifest makes `docker pull` do the right thing everywhere. Kept out of the MVP deliberately — it roughly doubles image CI time and nothing about the MVP needs it.

## What Changes

- Build and publish linux/amd64 + linux/arm64 images under the existing tag scheme, stitched into one manifest list per tag (`:X.Y.Z`, `:X.Y`, `:latest`, `:edge`, `:sha-<short>`).
- Native-arch CI runners for both builds (GitHub's hosted arm64 runners) — no QEMU emulation for build or test.
- The container smoke suite and the ffmpeg major-version assertion run per architecture; a render byte-level cross-arch comparison is explicitly *not* asserted (encoders may differ across arches at the bit level; the contract is decodability and duration, not identical bytes).
- `VERSIONS.md` records the per-arch ffmpeg versions if the alpine packages ever diverge.

## Capabilities

### New Capabilities

<!-- none -->

### Modified Capabilities

- `deployment`: published tags SHALL be multi-arch manifest lists (amd64 + arm64), each architecture smoke-verified on native hardware.

## Impact

- Modified: `.github/workflows/ci.yml` (arch matrix for image jobs, manifest stitch in publish), `Dockerfile` only if arch-conditional bits surface (none expected — alpine + apk are arch-transparent).
- Depends on: `add-docker-release` (the pipeline and tag scheme it extends).
- Position: post-MVP, lowest priority — schedule on demand (first arm64 deployment target or contributor), not by default order.
