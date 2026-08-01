## Why

Concurrent requests for the same not-yet-cached variant should not spawn duplicate ffmpeg processes (API doc §5): one render per in-flight cache key, all requesters subscribe to its chunk broadcast, late joiners catch up from partial data. Positioned first post-MVP: the MVP endpoint renders once per request (correct, wasteful for same-variant bursts), and this slice retrofits deduplication by swapping the endpoint's single spawn call for a coordinator subscribe — the coordinator broadcasts the identical message contract the pipeline emits, so the streaming loop is untouched.

## What Changes

- Registry keyed by cache key; `subscribe/1` either starts a render coordinator or joins the running one (race-free).
- Coordinator consumes the pipeline chunk stream, retains rendered-so-far data, broadcasts chunks to all subscribers; late joiners first receive the backlog, then live chunks.
- First subscriber is MISS, later ones COALESCED — the `X-Audio-Proxy: COALESCED` header (deferred from the endpoint slice) becomes real here, fulfilling the §5 coalescing promise.
- Render completes/fails once for everyone; subscriber death never kills the render for others — but last-subscriber-gone cancels it (nobody is listening; write-back policy owned by the variant-cache slice).
- Endpoint integration: replace the direct `Ffmpeg.Render` spawn with `RenderCoordinator.subscribe/2`; the coalesced-client end-to-end test (byte-equality + header) lands here.

## Capabilities

### New Capabilities

- `render-coalescing`: Per-cache-key render deduplication with subscriber broadcast and late-joiner catch-up.

### Modified Capabilities

<!-- none — render-http behavior gains the COALESCED header §5 already specifies -->

## Impact

- New: `lib/audio_proxy/render_coordinator.ex`, `Registry` in the supervision tree.
- Modified: the render endpoint's spawn call site (one function, per its design).
- Depends on: `add-ffmpeg-port-pipeline` (consumer contract), `add-render-endpoint` (the spawn point it replaces).
- Blocks: `add-render-semaphore` (acquire/release integrates into this coordinator), `add-variant-cache` (tee subscribes like a client).
- Position: first post-MVP slice, directly before `add-render-semaphore`.
