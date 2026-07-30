## Why

Without the cache, every request renders (fine for dev, wasteful in production). API doc §5: MISS responses tee to the variant bucket; subsequent requests HIT via 302 to a presigned variant URL (or proxied with Range support in `AP_SERVE_MODE=proxy`), putting S3/CDN on the hot path.

## What Changes

- Tee: a write-back subscriber joins each coalesced render and streams chunks to `s3://{AP_VARIANT_BUCKET}/{cache-key}` via multipart upload; upload failure never breaks client streams; incomplete renders are never persisted.
- HIT detection: variant-bucket HEAD before subscribing to a render; hit → `302` with short-lived presigned URL and `X-Audio-Proxy: HIT`.
- `AP_SERVE_MODE=proxy`: proxy the variant object with `Accept-Ranges`/206 passthrough.
- Unset `AP_VARIANT_BUCKET` = no cache: always render, no tee (per §6).

## Capabilities

### New Capabilities

- `variant-cache`: Variant write-back, HIT detection, redirect and proxied serving modes.

### Modified Capabilities

- `render-http`: The render endpoint SHALL check the variant cache before coalescing and serve HITs per §5 (endpoint flow gains the cache lookup step).

## Impact

- New: `lib/audio_proxy/variant_cache.ex` (lookup + tee subscriber).
- Modified: render endpoint action.
- Depends on: `add-render-endpoint`, `add-s3-client`, `add-render-coalescing`.
