## Context

Extends `add-docker-release`'s pipeline: same Dockerfile, same tag scheme, two architectures. The design questions are build strategy (emulation vs native) and what "verified" means per arch.

## Goals / Non-Goals

**Goals:**
- One `docker pull` that is native everywhere it matters; both arches held to the same smoke bar.

**Non-Goals:**
- linux/386, armv7, riscv (no audience); Windows containers; cross-arch bit-identical render output (see below).

## Decisions

- **Native runners over QEMU buildx emulation**: GitHub provides hosted arm64 runners; QEMU-emulated builds are 5–20× slower and the BEAM JIT under QEMU is a known flake source. Each arch builds *and smokes* on its own hardware; the publish job stitches digests into a manifest list (`docker buildx imagetools create`).
- **All-or-nothing publish**: a partial manifest (amd64 present, arm64 missing) is worse than a delayed release — a pull on the missing arch silently falls back to emulation or errors. Both smokes gate the single manifest push.
- **No cross-arch byte-equality assertion**: encoder output may legitimately differ at the bit level between architectures (float rounding, SIMD paths). The per-arch contract is the same as the existing smoke contract: decodable output, correct duration, pinned ffmpeg major. Cache keys are unaffected — variants are rendered per deployment, not per arch, and a mixed-arch fleet sharing one variant bucket accepts byte-level variance the same way an ffmpeg patch bump does.
- **Devcontainer stays amd64-recommended with native arm64 fallback** — the devcontainer image already exists for both via the base images; nothing to build here, just a docs note.

## Risks / Trade-offs

- [Doubled image CI time on every main push] → arch matrix runs in parallel on separate runners; wall-clock cost is ~the slower of the two, not the sum.
- [alpine's ffmpeg versions could diverge between arches] → the per-arch version assertion catches it; `VERSIONS.md` records both if they ever differ, and that state blocks a release until reconciled or consciously accepted.
- [Mixed-arch fleet + shared variant bucket → same cache key, arch-dependent bytes] → accepted and documented (equivalent to the existing ffmpeg-upgrade variance); deployments that require byte-stability pin one arch.
