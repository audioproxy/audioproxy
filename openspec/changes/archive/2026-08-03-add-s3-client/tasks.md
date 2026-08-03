## 1. The S3 layer

- [x] 1.1 `AudioProxy.S3`: a four-function facade over `ex_aws_s3` — `presign_get/3`, `head/2`, `put_stream/4`, `get_stream/3` — translating `ex_aws`'s errors into this codebase's vocabulary and keeping `:not_found` distinct from `:access_denied`
- [x] 1.2 `AudioProxy.S3.HttpClient`: an `ExAws.Request.HttpClient` over OTP's `:httpc`, with a dedicated profile sized against `AP_MAX_CONCURRENCY`
- [x] 1.3 Single-`PutObject` fast path plus 5 MiB part grouping, because `ExAws.S3.upload/4` refuses small objects and uploads one part per stream element
- [x] 1.4 Own the multipart abort, because `ExAws.S3.Upload` never calls `abort_multipart_upload/3`

## 2. Configuration

- [x] 2.1 The `AWS_*` credential group (`AWS_ACCESS_KEY_ID`, `AWS_SECRET_ACCESS_KEY`, `AWS_REGION`/`AWS_DEFAULT_REGION`, `AWS_SESSION_TOKEN`), validated all-or-nothing at boot
- [x] 2.2 `AP_S3_ENDPOINT` for S3-compatible stores, refusing a path, query, fragment or embedded credentials

## 3. Verification

- [x] 3.1 MinIO as a compose service in the devcontainer, one per worktree, publishing no host port
- [x] 3.2 `:minio` tag excluded by default and failing rather than skipping when the store is absent; CI starts MinIO and runs `--include integration --include minio`

## 4. Docs

- [x] 4.1 README: the `AWS_*` group, `AP_S3_ENDPOINT`, the no-IMDS limitation; `docs/s3-providers.md` for Backblaze B2, DigitalOcean Spaces, Hetzner and Scaleway; CLAUDE.md's dependency open question closed

## Deferred out of this change

Recorded rather than dropped, because each was planned here and moved deliberately.

- **`VariantStore.S3` and the backend parity suite.** Moved to a follow-up to keep this slice reviewable. Nothing in this change reads or writes the variant cache.
- **`AudioProxy.Source.S3.stat/1` and `ffmpeg_input/1`**, still `{:error, :no_backend}`. Blocked on deciding what HTTP status an S3 *outage* renders: `ErrorJSON`'s 404 row is deliberately blind, and an outage is not a source failure.
- **Request addressing.** This slice sends path-style for every request, which is `ex_aws`'s default — wrong for AWS regions launched after 2019, and unusable against Tigris. See `add-s3-addressing`.

## Note on the plan this replaced

The original tasks described a hand-rolled SigV4 signer, a `Bandit`-based fake S3, and 8 MiB parts. That was built, passed AWS's published known-answer vectors and MinIO, and was then deleted in favour of `ex_aws_s3` — roughly 2000 lines of signing and multipart orchestration that would have been ours to maintain. Volume decided it, not correctness. The reasoning is in CLAUDE.md's open questions.
