## 1. HIT serving

- [x] 1.1 `VariantCache.lookup/1` (`head/1`) in the render action before coalescing; miss → existing flow; `X-Audio-Proxy: HIT`
- [x] 1.2 Proxy mode: streamed passthrough — `200` + `Content-Length` + `Accept-Ranges` (not chunked), Range → `206`/`Content-Range`; progressive, no whole-object buffering
- [x] 1.3 Redirect mode: `302` + presigned URL (TTL config) + `Cache-Control: no-store`; presigning backends only

## 2. Tests

- [x] 2.1 HIT: second request spawns no subprocess (supervisor spy); unset store → always renders
- [x] 2.2 Range: 206 with the correct slice against the local backend
- [x] 2.3 Progressive delivery: first bytes of a proxied HIT before the store read completes; memory does not scale with variant size
- [x] 2.4 Framing contract: MISS chunked/no-`Accept-Ranges`, HIT length-declared/range-capable, same URL
- [x] 2.5 302: no-store header present; followed redirect carries the same `Content-Type`/`Cache-Control` as a proxied HIT (against fake S3 once available, else deferred to the parity suite)
  - The 302 half is covered against `AudioProxy.PresigningStore` (status, `Location`, `no-store`, `AP_PRESIGN_TTL`). *Following* the redirect needs a store that answers HTTP, so it is deferred to `add-s3-client`'s parity suite, as this task allows.

## 3. Docs

- [x] 3.1 API doc §5: HIT semantics per serve mode, the framing contract
- [x] 3.2 README: cache semantics (MISS/HIT), choosing a serve mode, CDN note (proxy mode collaborates; redirect routes around the edge)
