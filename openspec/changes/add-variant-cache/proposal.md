## Why

Without the cache, every request renders (fine for dev, wasteful in production). API doc §5: MISS responses tee the rendered bytes to a variant store; subsequent requests HIT, either by redirect to the store or proxied with Range support, keeping the proxy off the hot path.

**Where variants are cached is independent of where sources come from.** The earlier version of this change assumed S3 for both, which conflated two orthogonal axes and made the cache — the single largest production gap — wait on the much larger `add-s3-client` slice. A single node rendering from a mounted directory should be able to cache to a directory, with no object storage anywhere in the deployment. The cache is therefore defined against a storage behaviour with two backends, and the local one ships first.

## What Changes

- **`AP_VARIANT_STORE` replaces `AP_VARIANT_BUCKET`**, scheme-tagged the way sources already are: `file:///var/cache/audio_proxy` or `s3://bucket-name`. Unset still means no cache, always render (§6). The old name is not kept as an alias — pre-1.0, nothing deployed to migrate, and two spellings of one setting is worse than a rename.
- **A `VariantStore` behaviour**: `head/1`, `get_stream/2` (Range-aware), `put_stream/2` (atomic-or-absent), and `presign/2` for backends that can.
- **Local backend** (`file://`): writes to a temp file inside the store, then `File.rename/2` into place on completion. Atomicity comes from rename-within-a-filesystem, the local analogue of multipart-complete. Reads serve the file with Range support.
- **S3 backend** (`s3://`): multipart upload for atomicity, HEAD for lookup, presigned GET for redirect HITs. Lands with `add-s3-client`.
- **Serve mode becomes a backend capability.** `AP_SERVE_MODE=redirect` needs a presigned URL, which a directory cannot produce. Backends advertise whether they can redirect, and `redirect` against a store that cannot is a boot-time config error rather than a request-time surprise.
- HIT detection before coalescing; hit → serve per mode with `X-Audio-Proxy: HIT`.

## Capabilities

### New Capabilities

- `variant-cache`: Variant write-back, HIT detection, the storage behaviour and its backends, redirect and proxied serving modes.

### Modified Capabilities

- `render-http`: The render endpoint SHALL check the variant cache before coalescing and serve HITs per §5 (endpoint flow gains the cache lookup step).
- `app-runtime`: `AP_VARIANT_BUCKET` becomes `AP_VARIANT_STORE`, parsed as a scheme-tagged URL and validated against the serve mode at boot.

## Impact

- New: `lib/audio_proxy/variant_store.ex` (behaviour), `variant_store/local.ex`, `variant_store/s3.ex`, `lib/audio_proxy/variant_cache.ex` (lookup + tee subscriber).
- Modified: render endpoint action, `AudioProxy.Config`, API doc §5/§6, README configuration table.
- Depends on: `add-render-endpoint`, `add-render-coalescing`. **No longer depends on `add-s3-client`** — the local backend needs nothing from it, and the S3 backend is additive once that slice lands.
- **Eviction is deliberately unanswered here.** A bucket has lifecycle rules; a directory grows until the disk fills. Documented as a known gap rather than designed (see design.md).
