## 1. Coordinator

- [ ] 1.1 `Registry` (unique, keyed by cache key) + `DynamicSupervisor` in the tree
- [ ] 1.2 `RenderCoordinator.subscribe(cache_key, render_spec)`: start-or-join with race handling; atomic `{status, backlog}` join reply; subscriber monitors
- [ ] 1.3 Pipeline consumption: retain iodata backlog (with byte cap), broadcast chunks/done/error to subscribers
- [ ] 1.4 Semaphore integration: acquire before pipeline spawn (queue-full propagates to subscribers), release on terminate
- [ ] 1.5 Teardown: last-subscriber-DOWN cancel; post-done linger; error unregister-for-retry

## 2. Tests (fake pipeline via fake_cmd.sh / stub consumer contract)

- [ ] 2.1 Single-flight: concurrent subscribe burst → one child started (count via test spy), all streams byte-identical
- [ ] 2.2 Late joiner at every phase: after zero, some, and all chunks — concatenation equality, plus a seam property test with random join timing
- [ ] 2.3 MISS/COALESCED assignment; distinct keys independent
- [ ] 2.4 Lifecycle: kill one subscriber (others complete), kill all (subprocess cancelled + slot released), mid-render error (all notified, key retryable)
- [ ] 2.5 Backlog cap exceeded → render fails cleanly

## 3. Docs

- [ ] 3.1 Update README: coalescing semantics, `X-Audio-Proxy` values, memory-cap note
