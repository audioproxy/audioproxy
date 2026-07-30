## Why

Concurrent requests for the same not-yet-cached variant must not spawn duplicate ffmpeg processes (API doc §5): one render per in-flight cache key, all requesters subscribe to its chunk broadcast, late joiners catch up from partial data. This is the Registry-based layer CLAUDE.md prescribes between the pipeline and HTTP delivery.

## What Changes

- Registry keyed by cache key; `subscribe/1` either starts a render coordinator or joins the running one (race-free).
- Coordinator consumes the pipeline chunk stream, retains rendered-so-far data, broadcasts chunks to all subscribers; late joiners first receive the backlog, then live chunks.
- First subscriber is MISS, later ones COALESCED (surfaced in `X-Audio-Proxy`).
- Render completes/fails once for everyone; subscriber death never kills the render for others — but last-subscriber-gone cancels it (nobody is listening; write-back policy owned by the variant-cache slice).

## Capabilities

### New Capabilities

- `render-coalescing`: Per-cache-key render deduplication with subscriber broadcast and late-joiner catch-up.

### Modified Capabilities

<!-- none -->

## Impact

- New: `lib/audio_proxy/render_coordinator.ex`, `Registry` in the supervision tree.
- Depends on: `add-ffmpeg-port-pipeline` (consumer contract), `add-render-semaphore` (coordinator holds the slot).
- Blocks: `add-render-endpoint`, `add-variant-cache` (tee subscribes like a client).
