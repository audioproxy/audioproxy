## Why

Prospective-customer request, verbatim in spirit: new episodes from top-tier podcasts must jump a transcoding backlog so they publish on time. Today the render queue is strictly FIFO — a catalog backfill ahead of a fresh episode delays it by the whole backlog. Priority is a resource-allocation privilege and therefore must ride a *signed* surface; and it must not touch cache identity (identical bytes may never get two cache keys). Both constraints point at the warm batch, which is where ingest backlogs actually form.

## What Changes

- Warm batch entries (and whole batches) accept a `priority` field: `high` | `normal` (default) | `low`.
- Warm entries speak the admission classes `add-semaphore-classes` provides (`high`/`normal`/`low`; `interactive` remains unspellable — live renders always outrank warms). Strict ordering, no aging (a starved `low` backfill is the *point*; lazy render remains the safety net).
- Displaced warm entries (the semaphore's class-aware overflow) surface in the batch report as `rejected`, retryable.

## Capabilities

### New Capabilities

- `pro-render-priority`: The priority field on warm batches, its ordering guarantees, and the eviction policy.

### Modified Capabilities

<!-- none — the queue-classes contract moved to the OSS change `add-semaphore-classes`; this slice is a pure consumer -->

## Impact

- New: priority parsing in the warm payload; class plumbed into the coordinator's acquire.
- No other change or spec is amended.
- Depends on: `add-semaphore-classes` (OSS — the admission classes it speaks), `pro-warm-endpoint` (the signed surface priorities ride on).
- Explicitly not in scope: a priority URL option on interactive renders (would either pollute cache keys or require a cache-key-exempt option class — recorded as an open question in design.md); priority on `/{sig}/uploaded` policy triggers (arrives with upload policies, which will pass a policy-configured priority through this machinery).
- Position: PRO track, after `pro-warm-endpoint`.
