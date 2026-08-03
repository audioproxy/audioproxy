## Context

CLAUDE.md open question: `ex_aws_s3` vs `req` + `aws_signature`. Needs: presign GET, HEAD, multipart PUT. Dependency policy: prefer stdlib/OTP, boring code.

## Goals / Non-Goals

**Goals:**
- All three S3 operations with the smallest credible dependency footprint.
- Testable offline: SigV4 known-answer vectors + a local S3-compatible stub.

**Non-Goals:**
- General S3 API coverage; bucket management; credential providers beyond env vars (no IMDS/STS in v1 — document the limitation).

## Decisions

- **Hand-rolled SigV4 (~150 lines, `:crypto` + `URI`) over `ex_aws_s3`** — SigV4 is a stable, precisely specified algorithm with published test vectors; `ex_aws` would bring a dependency tree (`hackney` et al.) for three operations. This resolves the CLAUDE.md open question in favor of "minimal".
- **HTTP client: OTP's `:httpc`** for HEAD/PUT — already in the release, fine for our low-frequency control-plane calls. The data-plane GET is done by *ffmpeg*, not the BEAM (architecture decision), so we never need a high-performance Elixir HTTP client. Escape hatch: swap to `req` later behind the same `S3.Client` behaviour if `:httpc` warts bite.
- **`S3` is a behaviour** with the real client and a test double (plus a tiny Bandit-based fake S3 server for integration tests — we already ship a web server).
- **Multipart with 8 MiB parts**, `AbortMultipartUpload` in an `after` block; single-part fast path (`PutObject`) for streams that end under one part.
- **Path-style addressing when `AP_S3_ENDPOINT` is set** (MinIO-compatible), virtual-hosted otherwise.

## Risks / Trade-offs

- [Hand-rolled signing bugs are subtle] → known-answer tests from AWS's published SigV4 test suite; integration test against a real S3-compatible store (MinIO) in the devcontainer, tagged `:integration`.
- [`:httpc` has awkward defaults (e.g., no connect timeout tuning per request)] → wrap once in `S3.Client`; behaviour boundary makes a later swap mechanical.
- [Env-only credentials exclude IAM roles] → acceptable for v1; note in README, revisit when someone deploys on EC2/EKS.
