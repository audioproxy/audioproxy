## 1. Semaphore classes (the core delta)

- [ ] 1.1 Per-class wait queues in `AudioProxy.Semaphore` (`interactive > high > normal > low`); `acquire/1` gains a `class:` option defaulting to `interactive`; grant = oldest waiter of highest non-empty class
- [ ] 1.2 Priority-aware overflow: evict newest waiter of the lowest warm class when outranked (never interactive); eviction reply distinct from queue-full
- [ ] 1.3 Telemetry measurements gain the `class` dimension (depth per class, admissions, evictions)
- [ ] 1.4 Tests: class order on release; FIFO within class; classless-only behavior identical to plain FIFO (property vs. the pre-classes model); eviction scenarios; crash-safety unchanged per class (holder/waiter DOWN)

## 2. Warm payload priority

- [ ] 2.1 `priority` per entry and per batch (entry wins); unknown value → that entry `invalid`; plumb class into the coordinator's acquire
- [ ] 2.2 Tests: episode-jumps-backfill end-to-end (fake pipeline); default normal; evicted entries reported `rejected` and retryable; live GET admitted ahead of `high` warms

## 3. Docs

- [ ] 3.1 README (PRO) + `docs/`: priority semantics table, starvation-is-the-contract note, eviction policy, per-class telemetry; interactive-priority open question recorded
