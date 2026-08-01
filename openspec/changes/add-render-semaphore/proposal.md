## Why

ffmpeg is CPU-bound; unbounded concurrent renders would thrash the box. CLAUDE.md mandates a counting semaphore at `AP_MAX_CONCURRENCY` with a bounded wait queue overflowing to 429 (API doc §5). This is a small, self-contained OTP component. Positioned first post-MVP: the MVP runs uncapped — acceptable for demo/integration traffic, and the coordinator gains the acquire step here as a small integration diff — but this slice MUST land before the proxy sees any traffic it doesn't control.

## What Changes

- Counting-semaphore GenServer: `acquire/2` (blocking with queue + timeout), `release/1`, monitor-based crash-safe release.
- Bounded FIFO wait queue (`AP_QUEUE_SIZE`); overflow returns queue-full immediately (→ 429 + `Retry-After`).
- Coordinator integration: the render coordinator acquires a slot before spawning its pipeline and releases on terminate (deferred from `add-render-coalescing` when this slice moved post-MVP); the 429 path joins the render endpoint's error surface and end-to-end tests.
- Telemetry events for slot occupancy and queue depth (consumed later by the metrics slice).

## Capabilities

### New Capabilities

- `render-concurrency`: Global render-slot limiting with bounded queueing and crash-safe slot recovery.

### Modified Capabilities

<!-- none — the 429 row already exists in the render-http error contract; this slice makes it reachable -->

## Impact

- New: `lib/audio_proxy/semaphore.ex`, supervised singleton.
- Modified: render coordinator (acquire/release integration), render endpoint tests (429 + `Retry-After` end-to-end).
- Depends on: `init-project-scaffold`; integrates into `add-render-coalescing`'s coordinator.
- Blocks: `add-metrics-endpoint` (gauges). Position: first post-MVP slice, before any public exposure.
