## 1. Measure

- [x] 1.1 Probe cost against a local file and against an HTTP source: spawn, first byte, teardown, wall clock. Ruby script under `bin/`, reusing `bin/script_support.rb`'s plumbing; numbers into `design.md`
- [x] 1.2 Concurrency curve: probes at 1, 8, 32, 128, 512 in flight — wall clock per probe, scheduler utilisation, peak file descriptors and processes. Find the knee, and say what binds first
- [x] 1.3 Decide from the numbers whether §3's bound is needed at all once §2 lands, and record the decision in `design.md` either way

## 2. Coalesce probes per cache key

- [x] 2.1 One probe per in-flight cache key: concurrent requests for the same variant await one result rather than spawning their own, via `Registry` and a broadcast in the shape `AudioProxy.RenderCoordinator` already uses
- [x] 2.2 Lifecycle: a crashed or timed-out probe fails every waiter with the same classified reason, and leaves no entry behind (monitor-based, as the coordinator does with subscribers)
- [x] 2.3 A late joiner that arrives after the verdict gets it without a second spawn, and one that arrives after the entry is gone probes normally
- [x] 2.4 Tests: N concurrent requests for one key spawn exactly one probe (process-table assertion, as the render tests do); a refused source still refuses every waiter; `/info` and the render gate share the mechanism

## 3. Bound concurrent probes — only if 1.3 says so

- [ ] 3.1 A probe-specific counter, separate from `AudioProxy.Semaphore`'s render slots, with its own `AP_`-prefixed limit and a default derived from the measurements
- [ ] 3.2 Overflow answers 429 with `Retry-After`, through `AudioProxy.ErrorJSON`'s existing `{:queue_full, retry_after}` row — no new status, no new vocabulary
- [ ] 3.3 Tests: the cap holds under 3× its value racing (as `render-concurrency`'s own property does), a probe never waits behind a render slot, and a cache HIT still needs neither

## 4. Docs

- [ ] 4.1 `README.md` configuration table gains the new limit if 3.1 lands, phrased as what an operator would raise and when
- [x] 4.2 `docs/audio-proxy-api-v1.md` §4.3 currently says a probe "does not take an `AP_MAX_CONCURRENCY` slot" — extend it to say what it *does* take, so the two pools are both described
- [x] 4.3 `openspec/changes/add-audio-only-policy/design.md`'s deferral note points here; check it still reads true when this lands
