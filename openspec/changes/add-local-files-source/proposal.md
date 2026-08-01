## Why

The MVP chain currently needs `add-s3-client` for exactly two things: a presigned GET as ffmpeg's input and a HEAD for 404/413. A local-filesystem source (imgproxy's `local://` pattern) replaces both with a path handoff and `File.stat` — no signing code, no HTTP client, no fake-S3 test infrastructure — letting the MVP ship without any S3 dependency. S3 moves post-MVP, landing together with its real consumer, the variant cache.

## What Changes

- New source form `local://{path}` (both `plain/` and `enc/` encodings), resolved against a configured root directory (`AP_LOCAL_ROOT`); unset root = local sources disabled.
- Traversal-safe resolution: decoded paths are confined to the root (`Path.safe_relative`-based; `..`, absolute paths, and symlink escapes rejected) → authorization error (404, same no-oracle policy as the allowlist).
- Stat-based source metadata: existence → 404, size → 413 against `AP_MAX_SRC_BYTES`.
- The local backend of the storage seam (`stat/1`, `ffmpeg_input/1`) declared by `add-source-resolver`'s `Source.Type` behaviour, so `add-s3-client` and `add-remote-files-source` later add their backends behind the same contract — the render endpoint is written storage-agnostic from the start.
- Amendments to already-proposed slices: `add-render-endpoint` (stat instead of HEAD/presign, local fixtures instead of fake S3), `add-docker-release` (smoke test mounts a fixture volume), `add-audio-only-policy` (protocol whitelist becomes per-source-type: `file` for local, `https,tls,tcp` for HTTP).

## Capabilities

### New Capabilities

- `local-files`: Local-filesystem sources — root configuration, confinement, stat, and ffmpeg path handoff.

### Modified Capabilities

<!-- none — `source-resolution` defines the type contract; this registers one type behind it -->

## Impact

- New: local backend in `lib/audio_proxy/source/` (store seam + local impl); config gains `AP_LOCAL_ROOT`.
- Modified artifacts (this change's docs tasks): `add-render-endpoint`, `add-docker-release`, `add-audio-only-policy`, `add-info-endpoint` wording.
- Depends on: `add-source-resolver` (implements its `Source.Type` behaviour; implement directly after it).
- Reordering: replaces `add-s3-client` in the MVP chain; `add-s3-client` moves post-MVP, immediately before `add-variant-cache`. The `s3://` and `https://` source forms live in `add-remote-files-source`, also post-MVP — this is the MVP's only source type.
