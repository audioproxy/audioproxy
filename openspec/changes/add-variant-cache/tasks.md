## 1. Storage behaviour and config

- [ ] 1.1 `AudioProxy.VariantStore` behaviour: `head/1`, `get_stream/2` (Range-aware), `put_stream/3` (bytes + metadata), `presign/2`, `capabilities/0`; `@type t` and `@spec` on the seam, since it is a public contract per the typing convention
- [ ] 1.2 `AP_VARIANT_STORE` in `AudioProxy.Config`: parse the scheme, dispatch to a backend, reject unknown schemes; remove `AP_VARIANT_BUCKET`
- [ ] 1.3 Boot-time serve-mode validation: `AP_SERVE_MODE=redirect` against a store without `presign` aborts startup naming both variables

## 2. Local backend

- [ ] 2.1 `VariantStore.Local`: key → path mapping (fan out by key prefix so one directory does not accumulate every variant), `head/1` via `File.stat/1`
- [ ] 2.2 `put_stream/2` writes to a temp file **inside the store** and `File.rename/2`s into place — a cross-device rename is a copy and not atomic, which is the whole point
- [ ] 2.3 `get_stream/2`: stream the file in chunks rather than `File.read/1` into memory, so a large variant neither delays the first byte nor sizes the response by available RAM; with Range, serve only the requested slice
- [ ] 2.4 Boot check: store directory exists and is writable, failing loudly as `AP_LOCAL_ROOT` does

## 3. Tee write-back

- [ ] 3.1 `VariantCache.tee/2` Task subscriber: consume coordinator stream → `put_stream` **with the response metadata** (`Content-Type`, immutable `Cache-Control`, `ETag`) so a redirected fetch is served correctly without the proxy in the path; abort on error/cancel; log and instrument write failure without touching client streams
- [ ] 3.2 Coordinator integration: start tee when a store is configured; tee counts as subscriber (last-client-gone completes the render when cache on, cancels when off)

## 4. HIT serving

- [ ] 4.1 `VariantCache.lookup/1` in the endpoint before coalescing; miss → existing flow
- [ ] 4.2 Proxy mode: streamed passthrough with Range/206/`Accept-Ranges`/`Content-Length`; a plain GET is `200` + `Content-Length` (not chunked - the size is known, and declaring it is what buys seeking and resumption)
- [ ] 4.3 Redirect mode: 302 + presigned URL (TTL config), `X-Audio-Proxy: HIT` — S3 backend only

## 5. S3 backend

*Lands with or after `add-s3-client`; everything above works without it.*

- [ ] 5.1 `VariantStore.S3`: `head/1`, multipart `put_stream/2` with abort, `get_stream/2`, `presign/2`
- [ ] 5.2 Backend parity suite: run the same behaviour tests against both backends, asserting a client sees identical `Content-Type`, `ETag`, `Cache-Control` and range capability either way - the contract is the cache state, not the store

## 6. Tests

- [ ] 6.1 Write-back byte-equality: response bytes == stored bytes after MISS, both backends
- [ ] 6.2 No-partial: mid-render failure and cancel → nothing readable; write failure → client stream unaffected
- [ ] 6.3 HIT: second request spawns no subprocess (spy on the supervisor); unset store → always renders
- [ ] 6.4 Range: 206 with the correct slice, against the local backend and fake S3
- [ ] 6.5 Progressive delivery: assert the first bytes of a proxied HIT reach the client before the whole variant has been read from the store, and that memory does not scale with variant size
- [ ] 6.6 Slow-client full-speed render: throttled reader, assert the variant is complete before the client finishes
- [ ] 6.7 Disconnect policy: cache on → sole client disconnect still completes write-back; cache off → cancels
- [ ] 6.8 Config: `redirect` + `file://` store aborts boot; unknown scheme aborts boot
- [ ] 6.9 Metadata round trip: fetch a written-back variant straight from the store (bypassing the proxy) and assert `Content-Type` and `Cache-Control` match what the endpoint would have sent

## 7. Docs

- [ ] 7.1 API doc §5/§6: variant *store* rather than bucket, `AP_VARIANT_STORE`, serve mode as a backend capability. A contract change to the source of truth, so it lands with the code rather than after it
- [ ] 7.2 README: cache semantics (MISS/HIT), serve modes, choosing a backend, and **an explicit statement that a `file://` store is unbounded and the operator is responsible for it** until eviction is designed
- [ ] 7.3 README: a local store on a container's writable layer is lost with the container, so it wants a volume
