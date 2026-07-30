## 1. Tee write-back

- [ ] 1.1 `VariantCache.tee/2` Task subscriber: consume coordinator stream → `S3.put_stream` multipart; abort on error/cancel; log+telemetry on upload failure without touching client streams
- [ ] 1.2 Coordinator integration: start tee when bucket configured; tee counts as subscriber (last-client-gone completes render when cache on; cancels when off)

## 2. HIT serving

- [ ] 2.1 `VariantCache.lookup/1` (HEAD) in the endpoint before coalescing; miss → existing flow
- [ ] 2.2 Redirect mode: 302 + presigned URL (TTL config), `X-Audio-Proxy: HIT`
- [ ] 2.3 Proxy mode: streamed passthrough with Range/206/`Accept-Ranges`/`Content-Length` forwarding

## 3. Tests (fake S3 + real ffmpeg where tagged)

- [ ] 3.1 Write-back byte-equality: response bytes == bucket object bytes after MISS
- [ ] 3.2 No-partial: mid-render failure and cancel → abort called, no object; upload failure → client stream unaffected
- [ ] 3.3 HIT: second request 302s (no subprocess spawned — spy on supervisor), header check; unset bucket → always renders
- [ ] 3.4 Proxy mode: Range request → 206 with correct slice against fake S3
- [ ] 3.5 Slow-client full-speed render: throttled reader, assert object complete before client finishes
- [ ] 3.6 Disconnect policy: cache on → sole client disconnect still completes write-back; cache off → cancels

## 4. Docs

- [ ] 4.1 Update README: cache semantics (MISS/HIT/COALESCED), serve modes, bucket lifecycle recommendation
