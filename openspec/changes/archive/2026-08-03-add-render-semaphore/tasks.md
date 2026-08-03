## 1. Semaphore

- [x] 1.1 `AudioProxy.Semaphore` GenServer: `acquire/1` (opts: timeout), `release/1`, capacity + queue from config
- [x] 1.2 Monitors for holders and waiters; DOWN handling (release slot / drop waiter); idempotent double-release
- [x] 1.3 Telemetry events with occupancy and queue-depth measurements; Retry-After estimate from recent render durations

## 2. Tests

- [x] 2.1 Unit: grant under capacity, FIFO order, `{:error, :queue_full}` on overflow, release grants next waiter
- [x] 2.1a An input that never yields bytes (a FIFO placed under `AP_LOCAL_ROOT`, a stalled origin) holds its slot until `AP_RENDER_TIMEOUT`. Assert the timeout path releases the slot and that queued waiters are then granted — the slot accounting must survive a render that hangs rather than fails. `Source.ffmpeg_input/1` refuses FIFOs as of `add-local-files-source`, so this is defence in depth for the remote backends
- [x] 2.2 Crash-safety: kill a holder → slot recovered; kill a waiter → queue shrinks; caller-timeout race leaves no leaked slot
- [x] 2.3 Concurrency property: N tasks (N ≫ cap) hammer acquire/work/release with random crashes; invariant asserted throughout — held ≤ cap, final state fully released
- [x] 2.4 Telemetry: events fire with expected measurements (attach test handler)

## 3. Docs

- [x] 3.1 Update README: `AP_MAX_CONCURRENCY`, `AP_QUEUE_SIZE` behavior, 429 semantics
