## Why

Operating a render farm blind is untenable: queue depth, render durations, cache hit ratio, and error rates are the four signals that tell an operator whether to scale, and API doc §2 specifies an unsigned, bind-restricted `GET /metrics` in Prometheus format.

## What Changes

- Telemetry events across existing components (semaphore already emits; add render start/stop/error with duration and format, cache hit/miss/coalesced, HTTP status counts, write-back failures).
- Metrics aggregation from telemetry into counters/gauges/histograms; Prometheus text-format exposition at `GET /metrics`.
- Exposure restricted by bind address (`AP_METRICS_BIND`, default loopback) — unsigned but not public.

## Capabilities

### New Capabilities

- `observability`: Telemetry instrumentation and Prometheus exposition.

### Modified Capabilities

<!-- none — instrumentation only, no behavioral change to existing capabilities -->

## Impact

- New: `lib/audio_proxy/metrics.ex` (+ separate metrics listener or router gate).
- Touches (instrumentation-only): coordinator, endpoint actions, variant cache, semaphore (events exist).
- Depends on: `add-render-endpoint` (things worth measuring exist); extended by later slices as they land.
