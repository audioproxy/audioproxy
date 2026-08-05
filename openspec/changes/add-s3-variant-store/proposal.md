## Why

`AP_VARIANT_STORE` accepts `file:///path` and refuses `s3://bucket` at boot with "the S3 backend is a separate slice". This is that slice. `add-s3-client` shipped every operation the backend needs — HEAD, streaming PUT of unknown length, bounded GET, presigned URLs — and explicitly deferred `VariantStore.S3` itself "to keep this slice reviewable".

Two things are blocked behind it, and the second is easy to miss. The obvious one: a variant cache that survives a container restart and is shared between nodes, instead of a directory that only the node which rendered it can read. The other: **`AP_SERVE_MODE=redirect` is the documented default and is currently unusable.** Redirect mode answers a HIT with a 302 to a presigned variant URL, so `Config.validate!/1` refuses it against any store lacking the `:presign` capability — and `file://` lacks it. Every working deployment today is therefore in proxy mode, serving every cached byte through the BEAM, which is exactly the hot path §5's default was designed to leave.

## What Changes

- `AudioProxy.VariantStore.S3` implementing the four mandatory callbacks plus `presign/2`, declaring `capabilities/0` as `[:presign]`.
- `AP_VARIANT_STORE=s3://bucket` accepted at boot, replacing the raise; validated the way `file://` is — that the bucket is reachable and writable, so a container pointed at a bucket it cannot write fails to boot rather than rendering everything twice, silently.
- A **backend parity suite**: one set of assertions run against both backends, so `file://` and `s3://` are proved to answer the seam identically rather than merely intended to. This is what `add-s3-client` named and deferred along with the backend.
- With `:presign` available, `AP_SERVE_MODE=redirect` becomes reachable and its 302 path gets its first end-to-end test.

## Capabilities

### New Capabilities

<!-- none — this fills a backend behind an existing seam -->

### Modified Capabilities

- `variant-cache`: an object-storage backend, the parity guarantee between backends, and the redirect serve mode becoming reachable.
- `s3-access`: the variant-store backend as a consumer of this layer, and how its failures classify.

## Impact

- New `lib/audio_proxy/variant_store/s3.ex`; `lib/audio_proxy/config.ex` (the `s3://` branch of the store parser and its boot-time writability probe).
- Test surface: the parity suite runs the existing local assertions against MinIO, so the harness `add-s3-client` established is reused rather than extended.
- Depends on `add-s3-source-backend` only for its error classification, which this slice reuses rather than redefines — the two are otherwise independent and can land in either order.
- No new dependencies; no new config variables beyond the `s3://` form of one that exists.
