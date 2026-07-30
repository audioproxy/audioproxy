## Why

Three S3 interactions power the whole system: presigned GET URLs (ffmpeg input + HIT redirects), object existence checks (cache HIT detection), and streaming PUT (variant write-back). CLAUDE.md leaves the client choice open (`ex_aws_s3` vs minimal); this slice decides it and builds the layer.

## What Changes

- Decide the client approach (design.md): hand-rolled SigV4 with stdlib `:crypto` + a minimal HTTP client, keeping the dependency policy intact.
- Implement SigV4 presigned GET URL generation (configurable expiry).
- Implement HEAD (existence + size + ETag) and streaming multipart PUT.
- Credentials from the standard AWS env vars (+ optional endpoint override for MinIO/localstack-style testing).

## Capabilities

### New Capabilities

- `s3-access`: SigV4 signing/presigning, object HEAD, and multipart upload against S3-compatible stores.

### Modified Capabilities

<!-- none -->

## Impact

- New: `lib/audio_proxy/s3/{sigv4,client}.ex`.
- New config: standard `AWS_*` vars, `AP_S3_ENDPOINT` (test/dev override), presign TTL.
- Depends on: `init-project-scaffold`.
- Blocks: `add-render-endpoint` (presigned input), `add-variant-cache` (HEAD/PUT/redirect), `add-info-endpoint`.
