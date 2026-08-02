## 0. Decide whether to build this

- [ ] 0.1 **Decide whether to close this change.** Measurement (design.md) shows no trigger reaches a browser: Chrome sends `Range: bytes=0-` on every first media request, and a chunked response marks the element non-seekable so a seek range is never sent. Any mechanism therefore serves only deliberate, non-browser clients — who can already warm the cache with one discarded request. **Closing is the expected outcome.** Implement only if a concrete client needs materialisation and cannot warm; everything below assumes that.

## 1. Trigger and delivery

- [ ] 1.1 `/sync/{signature}/{options}/{source}` prefix as the materialise signal - reachable from `<audio src>` because the *page author* picks the URL, which is what `Range` could never be (a browser sends `Range: bytes=0-` on every first media request). No path option and no query parameter: `{options}` stays byte-identical, so both spellings resolve to one cache key and one stored object
- [ ] 1.2 Materialise via the cache path where a store is configured: render → write back → serve as a HIT, reusing `add-variant-cache`'s range and metadata handling rather than a second implementation
- [ ] 1.2a Sign the prefix: `/sync/...` and the plain URL carry different signatures, so holding a streaming URL cannot be escalated into a held render slot by prepending a path segment
- [ ] 1.2b Generalise `AudioProxy.Plugs.VerifySignature`, which today assumes the signature is the first path segment (`String.split(path, "/", parts: 3)`). Security-sensitive: wants its own review, and should be settled together with the reserved `/hls/` prefix so the codebase does not end up with one signed prefix and one unsigned one
- [ ] 1.3 Response shaping: `200` + `Content-Length` + `Accept-Ranges` for a whole-object materialise, `206` + `Content-Range` for a range

## 2. Spooling when no store is configured

- [ ] 2.1 `AP_RENDER_SPOOL` (directory) with boot validation: exists, writable, not `/`
- [ ] 2.2 Spool to a temp file, serve from it, remove it on completion, failure and cancellation alike
- [ ] 2.3 Degrade to a chunked MISS when there is neither store nor spool — the documented default beats a 500

## 3. Limits

- [ ] 3.1 Acquire a render slot for the whole materialisation; verify a burst queues and then 429s rather than starving streaming clients
- [ ] 3.2 `AP_RENDER_TIMEOUT` applies unchanged: kill and answer `504`

## 4. Tests

- [ ] 4.1 Range on an uncached variant → `206` with the correct slice
- [ ] 4.2 Cache-key identity: streaming and materialising the same variant produce one key and one stored object (property test, alongside the existing round-trip properties)
- [ ] 4.3 Default unchanged: no range, no signal → chunked `200`, no `Accept-Ranges`
- [ ] 4.4 Second request after a materialise is a HIT with no subprocess
- [ ] 4.5 Spool: memory does not scale with variant size; no spool file survives success, failure or cancellation
- [ ] 4.6 No store and no spool → chunked MISS, not an error
- [ ] 4.7 Limits: burst → 429; overrun → 504

## 5. Docs

- [ ] 5.1 API doc §5: a MISS has two shapes, with the trigger and the trade stated. Contract change to the source of truth, lands with the code
- [ ] 5.2 README: `/sync/` trades time-to-first-byte for a working scrubber. Say so where the `<audio>` snippet explains why the scrubber is dead, and note that warming the cache achieves the same thing without it
- [ ] 5.3 `AP_RENDER_SPOOL` in the configuration table
