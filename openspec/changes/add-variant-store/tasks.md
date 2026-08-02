## 1. Behaviour and config

- [ ] 1.1 `AudioProxy.VariantStore` behaviour: `head/1`, `get_stream/2` (Range-aware), `put_stream/3` (bytes + metadata), `presign/2`, `capabilities/0`; `@type t`/`@spec` on the seam
- [ ] 1.2 `AP_VARIANT_STORE` in `AudioProxy.Config`: scheme parse + backend dispatch, unknown scheme rejected; remove `AP_VARIANT_BUCKET`
- [ ] 1.3 Boot validation: `file://` path exists and writable; `AP_SERVE_MODE=redirect` against a store without `presign` aborts naming both variables

## 2. Local backend

- [ ] 2.1 `VariantStore.Local`: key→path with prefix fan-out; `head/1` via `File.stat/1`
- [ ] 2.2 `put_stream/3`: temp file inside the store → `File.rename/2` on completion; metadata persisted (sidecar/xattr, tested via store-direct fetch)
- [ ] 2.3 `get_stream/2`: chunked streaming reads (never whole-file into memory), Range slices

## 3. Tee write-back

- [ ] 3.1 Tee Task subscriber: coordinator stream → `put_stream/3` with response metadata; abort on error/cancel; write failure logged + instrumented, client streams untouched
- [ ] 3.2 Coordinator integration: tee starts when a store is configured; disconnect policy (tee counts as subscriber — complete when cache on, cancel when off)

## 4. Tests

- [ ] 4.1 Write-back byte-equality (response bytes == stored bytes); metadata round trip via store-direct fetch
- [ ] 4.2 No-partial: mid-render failure and cancel → nothing readable; write failure → client unaffected
- [ ] 4.3 Slow-client full-speed: throttled reader, variant complete before client finishes
- [ ] 4.4 Disconnect policy both ways (store on: completes; store off: cancels)
- [ ] 4.5 Boot: unknown scheme, unusable path, redirect+`file://` each abort naming their variables

## 5. Docs

- [ ] 5.1 API doc §6: `AP_VARIANT_STORE` (store, not bucket); serve mode as a backend capability
- [ ] 5.2 README: configuring a store; **a `file://` store is unbounded and the operator owns it**; a store on the container's writable layer wants a volume
