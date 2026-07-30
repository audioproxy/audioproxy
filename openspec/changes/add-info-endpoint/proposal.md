## Why

`GET /{sig}/info/{source}` (API doc §2, §4) gives clients probe metadata — duration, sample rate, channels — needed to build sensible variant URLs (e.g., trim ranges for previews). Independent of the render path; reuses subprocess plumbing with `ffprobe`.

## What Changes

- `info` recognized in the options position (no processing options allowed with it).
- Run `ffprobe -show_format -show_streams -print_format json` against a presigned source URL; map/filter to the §4 JSON shape (`format`, `duration`, `sample_rate`, `channels`, `bit_depth`, `bitrate`, `size`, `tags`).
- Aggressive caching: `ETag` from source identity + source ETag; `Cache-Control` immutable semantics per §4.
- Errors: 404 unreadable source, 415 unprobeable, 401/413 as usual.

## Capabilities

### New Capabilities

- `source-info`: Signed metadata endpoint mapping ffprobe output to a stable JSON contract.

### Modified Capabilities

<!-- none — new route; render-http plug chain is reused unchanged -->

## Impact

- New: `lib/audio_proxy/ffprobe.ex`, info action in router.
- Depends on: `add-render-endpoint` (plug chain), `add-ffmpeg-port-pipeline` (subprocess wrapper), `add-s3-client`.
