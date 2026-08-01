## Why

`add-remote-files-source` defines the `https://` form but ships it with a "no backend" storage stub — an HTTPS source parses and authorizes, and cannot be rendered. This change fills that stub: metadata via HEAD, ffmpeg input as the canonical URL itself. It is the HTTPS twin of `add-s3-client`'s S3 backend, packaged the same way (a backend behind the seam is its own change), sized well under the review target.

## What Changes

- HTTPS `stat/1`: HEAD request → size + ETag material; an origin that withholds `Content-Length` is reported as existing with unknown size (the render byte cap enforces `AP_MAX_SRC_BYTES` post-hoc); failures and 4xx/5xx map to not-found.
- HTTPS `ffmpeg_input/1`: the canonical URL — ffmpeg does its own fetching.
- Replaces the HTTPS "no backend" stub and its pinning test; the S3 stub stays until `add-s3-client`.

## Capabilities

### New Capabilities

<!-- none -->

### Modified Capabilities

- `remote-sources`: gains the HTTPS storage backend requirement (HEAD-based metadata with unknown-size tolerance, URL as render input).

## Impact

- New: HEAD client wrapping in `lib/audio_proxy/source/https.ex` (no new deps — `:httpc`).
- Depends on: `add-remote-files-source` (the form and stub it replaces).
- Position: post-MVP, directly after `add-remote-files-source`; independent of `add-s3-client`.
