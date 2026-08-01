## Why

Three S3 interactions power the production deployment: presigned GET URLs (ffmpeg input + HIT redirects), object existence checks (cache HIT detection), and streaming PUT (variant write-back). CLAUDE.md leaves the client choice open (`ex_aws_s3` vs minimal); this slice decides it and builds the layer. Positioned post-MVP: the MVP renders from local files (`add-local-files-source`), so S3 lands together with its main consumer, the variant cache.

## What Changes

- Decide the client approach (design.md): hand-rolled SigV4 with stdlib `:crypto` + a minimal HTTP client, keeping the dependency policy intact.
- Implement SigV4 presigned GET URL generation (configurable expiry).
- Implement HEAD (existence + size + ETag) and streaming multipart PUT.
- Implement the S3 backend of the storage seam (the `Source.Type` callbacks declared by `add-source-resolver`): `stat/1` via HEAD, `ffmpeg_input/1` via presigned GET — the render/info flows gain S3 sources with no changes of their own.
- Credentials from the standard AWS env vars (+ optional endpoint override for MinIO/localstack-style testing).

## Capabilities

### New Capabilities

- `s3-access`: SigV4 signing/presigning, object HEAD, and multipart upload against S3-compatible stores.

### Modified Capabilities

<!-- none — the storage seam contract is defined in `local-files`; this adds a backend behind it -->

## Impact

- New: `lib/audio_proxy/s3/{sigv4,client}.ex`, S3 backend in the source store.
- New config: standard `AWS_*` vars, `AP_S3_ENDPOINT` (test/dev override), presign TTL.
- Depends on: `add-source-resolver` (the seam it implements a backend for), `add-remote-files-source` (the `s3://` source form it renders).
- Blocks: `add-variant-cache` (HEAD/PUT/redirect). Position: first post-MVP slice, immediately before `add-variant-cache`.
