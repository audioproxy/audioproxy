## Why

ffmpeg is CPU-bound; unbounded concurrent renders would thrash the box. CLAUDE.md mandates a counting semaphore at `AP_MAX_CONCURRENCY` with a bounded wait queue overflowing to 429 (API doc §5). This is a small, self-contained OTP component.

## What Changes

- Counting-semaphore GenServer: `acquire/2` (blocking with queue + timeout), `release/1`, monitor-based crash-safe release.
- Bounded FIFO wait queue (`AP_QUEUE_SIZE`); overflow returns queue-full immediately (→ 429 + `Retry-After`).
- Telemetry events for slot occupancy and queue depth (consumed later by the metrics slice).

## Capabilities

### New Capabilities

- `render-concurrency`: Global render-slot limiting with bounded queueing and crash-safe slot recovery.

### Modified Capabilities

<!-- none -->

## Impact

- New: `lib/audio_proxy/semaphore.ex`, supervised singleton.
- Depends on: `init-project-scaffold`.
- Blocks: `add-render-endpoint` (wraps every render), `add-metrics-endpoint` (gauges).
