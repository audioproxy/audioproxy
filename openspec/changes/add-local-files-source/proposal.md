## Why

The MVP chain currently needs `add-s3-client` for exactly two things: a presigned GET as ffmpeg's input and a HEAD for 404/413. A local-filesystem source (imgproxy's `local://` pattern) replaces both with a path handoff and `File.stat` — no signing code, no HTTP client, no fake-S3 test infrastructure — letting the MVP ship without any S3 dependency. S3 moves post-MVP, landing together with its real consumer, the variant cache.

## What Changes

- New source form `local://{path}` (both `plain/` and `enc/` encodings), resolved against a configured root directory (`AP_LOCAL_ROOT`); unset root = local sources disabled.
- Traversal-safe resolution: decoded paths are confined to the root (`Path.safe_relative`-based; `..`, absolute paths, and symlink escapes rejected) → authorization error (404, same no-oracle policy as the allowlist).
- Stat-based source metadata: existence → 404, size → 413 against `AP_MAX_SRC_BYTES`.
- A minimal source-store seam (`stat/1` + ffmpeg input from a resolved source) so `add-s3-client` later adds the S3 backend behind the same seam — the render endpoint is written storage-agnostic from the start.
- Amendments to already-proposed slices: `add-render-endpoint` (stat instead of HEAD/presign, local fixtures instead of fake S3), `add-docker-release` (smoke test mounts a fixture volume), `add-audio-only-policy` (protocol whitelist becomes per-source-type: `file` for local, `https,tls,tcp` for HTTP).

## Capabilities

### New Capabilities

- `local-files`: Local-filesystem sources — root configuration, confinement, stat, and ffmpeg path handoff.

### Modified Capabilities

- `source-resolution`: gains the `local://` source form and its canonical identity (delta on the not-yet-implemented `add-source-resolver` spec; implemented together).

## Impact

- New: local backend in `lib/audio_proxy/source/` (store seam + local impl); config gains `AP_LOCAL_ROOT`.
- Modified artifacts (this change's docs tasks): `add-render-endpoint`, `add-docker-release`, `add-audio-only-policy`, `add-info-endpoint` wording.
- Depends on: `add-source-resolver` (extends its grammar; implement directly after it).
- Reordering: replaces `add-s3-client` in the MVP chain; `add-s3-client` moves post-MVP, immediately before `add-variant-cache`.
