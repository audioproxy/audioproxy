## Why

Prospective-customer request, verbatim in spirit: new episodes from top-tier podcasts must jump a transcoding backlog so they publish on time. Today the render queue is strictly FIFO — a catalog backfill ahead of a fresh episode delays it by the whole backlog. Priority is a resource-allocation privilege and therefore must ride a *signed* surface; and it must not touch cache identity (identical bytes may never get two cache keys). Both constraints point at the warm batch, which is where ingest backlogs actually form.

## What Changes

- Warm batch entries (and whole batches) accept a `priority` field: `high` | `normal` (default) | `low`.
- The render semaphore's wait queue becomes class-aware: `interactive` (any live GET render — always first) > `high` > `normal` > `low`; FIFO within a class. Strict ordering, no aging in v1 (a starved `low` backfill is the *point* of the feature; correctness is unaffected — lazy render remains the safety net).
- Overflow policy becomes priority-aware: when the queue is full and a higher-class entry arrives, the newest lowest-class *warm* entry is evicted (reported `rejected`, retryable) rather than the arrival being refused; interactive entries are never evicted.
- Telemetry: queue-depth measurements gain a class dimension (the metrics slice picks the label up for free).

## Capabilities

### New Capabilities

- `pro-render-priority`: The priority field on warm batches, its ordering guarantees, and the eviction policy.

### Modified Capabilities

- `render-concurrency`: the semaphore's queue SHALL support ordered admission classes with FIFO inside each class (delta on `add-render-semaphore`'s spec — the one place this feature touches core, kept to the queue-ordering contract).

## Impact

- New: priority parsing in the warm payload, class-aware queue in the semaphore, per-class telemetry measurements.
- Modified capability: `render-concurrency` (above). No other change or spec is amended.
- Depends on: `add-render-semaphore` (the queue), `pro-warm-endpoint` (the signed surface priorities ride on).
- Explicitly not in scope: a priority URL option on interactive renders (would either pollute cache keys or require a cache-key-exempt option class — recorded as an open question in design.md); priority on `/{sig}/uploaded` policy triggers (arrives with upload policies, which will pass a policy-configured priority through this machinery).
- Position: PRO track, after `pro-warm-endpoint`.
