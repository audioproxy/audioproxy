## Why

This slice assembles the pieces into the core resource: `GET /{sig}/{options}/{source}` streaming a rendered variant as chunked 200 (API doc §2, §5 MISS path). Signature, options, source, semaphore, pipeline, and coalescing all exist; here they become an HTTP endpoint with the full §5 error surface.

## What Changes

- Router route + plug chain: verify signature → parse options → resolve source → source stat + ffmpeg input via the storage seam → subscribe to coalesced render.
- Chunked 200 delivery: chunks forwarded as they arrive; headers per §5 (Content-Type, `Cache-Control: public, max-age=31536000, immutable`, `ETag` = cache key, `X-Audio-Proxy: MISS|COALESCED`, `Content-Disposition` for `dl`).
- Client-disconnect detection → unsubscribe (feeding coalescing's last-subscriber cancel; no orphaned ffmpeg per CLAUDE.md).
- Error mapping: 401/404/413/415/422/429 (+`Retry-After`)/504 as JSON bodies; `AP_MAX_SRC_BYTES` enforced via the source stat.
- End-to-end integration tests over a real socket (Bandit) with local fixture sources + real ffmpeg (S3 sources join the matrix when `add-s3-client` lands post-MVP).

## Capabilities

### New Capabilities

- `render-http`: The signed render endpoint — request pipeline wiring, chunked MISS delivery, and the §5 error contract.

### Modified Capabilities

<!-- none -->

## Impact

- Modified: `lib/audio_proxy/router.ex`; new `lib/audio_proxy/plugs/*`, `lib/audio_proxy/error_json.ex`.
- Depends on: `add-signature-verification`, `add-options-parser`, `add-source-resolver` (decoding + the storage seam), `add-local-files-source` (the MVP source type behind it), `add-render-semaphore`, `add-ffmpeg-port-pipeline`, `add-render-coalescing`.
- Blocks: `add-variant-cache` (adds HIT/tee to this endpoint), `add-peaks-format`, `add-info-endpoint` (shares plug chain).
