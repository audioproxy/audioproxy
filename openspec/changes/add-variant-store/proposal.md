## Why

`add-variant-cache` grew to 26 tasks — past the review-size convention. This is its first half: the storage machinery. A `VariantStore` behaviour with a local `file://` backend and the write-back tee, so completed renders persist atomically with their metadata. Serving from the store (HIT paths, Range, framing) follows in the slimmed `add-variant-cache`; the S3 backend moves to `add-s3-client`, which owns the client it needs.

## What Changes

- **`AP_VARIANT_STORE` replaces `AP_VARIANT_BUCKET`**, scheme-tagged (`file:///var/cache/audio_proxy` or `s3://bucket`); unset = no cache, always render. No alias for the old name — pre-1.0, nothing deployed.
- **`VariantStore` behaviour**: `head/1`, `get_stream/2` (Range-aware), `put_stream/3` (bytes + metadata), `presign/2`, `capabilities/0` — `@type t`/`@spec` on the seam per the typing convention.
- **Local backend**: key→path with prefix fan-out, temp-file-inside-the-store + `File.rename/2` atomicity (rename within one filesystem — the local analogue of multipart-complete), streamed reads.
- **Write-back tee**: a coordinator subscriber streaming completed renders into the store with their response metadata (`Content-Type`, immutable `Cache-Control`, `ETag`) so a store-direct fetch serves correctly; abort on error/cancel — atomic-or-absent; write failures logged and instrumented, never visible to clients.
- **Disconnect policy change**: with a store configured the tee counts as a subscriber — last-*client*-gone completes the render into the store instead of cancelling (next request is a HIT); cache off keeps today's cancel.
- **Boot validation**: unknown scheme, unusable `file://` path, and `AP_SERVE_MODE=redirect` against a store without `presign` all abort startup naming the variables.

## Capabilities

### New Capabilities

- `variant-cache`: created here with the storage and write-back requirements; the serving requirements arrive with `add-variant-cache`.

### Modified Capabilities

- `app-runtime`: `AP_VARIANT_BUCKET` becomes `AP_VARIANT_STORE`, parsed as a scheme-tagged URL and validated against the serve mode at boot.

## Impact

- New: `lib/audio_proxy/variant_store.ex` (behaviour), `variant_store/local.ex`, tee subscriber.
- Modified: `AudioProxy.Config`, coordinator (tee start + disconnect policy), API doc §6.
- Depends on: merged code only (coalescing, render endpoint).
- Blocks: `add-variant-cache` (serves from this store), `add-s3-client` (adds the S3 backend behind this behaviour).
- **Eviction deliberately unanswered**: a `file://` store grows until the disk fills; documented as the operator's responsibility until usage data justifies a design (open question in design.md).
