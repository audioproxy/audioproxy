## 1. Coordinator

- [ ] 1.1 `Registry` (unique, keyed by cache key) + `DynamicSupervisor` in the tree
- [ ] 1.2 `RenderCoordinator.subscribe(cache_key, render_spec)`: start-or-join with race handling; atomic `{status, backlog}` join reply; subscriber monitors
- [ ] 1.3 Pipeline consumption: retain iodata backlog (with byte cap), broadcast chunks/done/error to subscribers
- [ ] 1.4 Teardown: last-subscriber-DOWN cancel; post-done linger; error unregister-for-retry

## 2. Endpoint integration

- [ ] 2.1 Replace the endpoint's direct `Ffmpeg.Render` spawn with `RenderCoordinator.subscribe/2`; `X-Audio-Proxy` gains `COALESCED` for joiners

## 3. Tests (fake pipeline via fake_cmd.sh / stub consumer contract)

- [ ] 3.1 Single-flight: concurrent subscribe burst → one child started (count via test spy), all streams byte-identical
- [ ] 3.2 Late joiner at every phase: after zero, some, and all chunks — concatenation equality, plus a seam property test with random join timing
- [ ] 3.3 MISS/COALESCED assignment; distinct keys independent
- [ ] 3.4 Lifecycle: kill one subscriber (others complete), kill all (subprocess cancelled), mid-render error (all notified, key retryable)
- [ ] 3.5 Backlog cap exceeded → render fails cleanly
- [ ] 3.6 Full-stack (`@tag :ffmpeg`, moved from the endpoint slice): coalesced second client — byte-equality with the first client's stream + `COALESCED` header

## 4. Docs

- [ ] 4.1 Update README: coalescing semantics, `X-Audio-Proxy` values, memory-cap note

Note: semaphore acquire/release integration (and its slot-released teardown
assertions) lives in `add-render-semaphore`, which directly follows this slice.
