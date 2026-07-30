## 1. Semaphore

- [ ] 1.1 `AudioProxy.Semaphore` GenServer: `acquire/1` (opts: timeout), `release/1`, capacity + queue from config
- [ ] 1.2 Monitors for holders and waiters; DOWN handling (release slot / drop waiter); idempotent double-release
- [ ] 1.3 Telemetry events with occupancy and queue-depth measurements; Retry-After estimate from recent render durations

## 2. Tests

- [ ] 2.1 Unit: grant under capacity, FIFO order, `{:error, :queue_full}` on overflow, release grants next waiter
- [ ] 2.2 Crash-safety: kill a holder → slot recovered; kill a waiter → queue shrinks; caller-timeout race leaves no leaked slot
- [ ] 2.3 Concurrency property: N tasks (N ≫ cap) hammer acquire/work/release with random crashes; invariant asserted throughout — held ≤ cap, final state fully released
- [ ] 2.4 Telemetry: events fire with expected measurements (attach test handler)

## 3. Docs

- [ ] 3.1 Update README: `AP_MAX_CONCURRENCY`, `AP_QUEUE_SIZE` behavior, 429 semantics
