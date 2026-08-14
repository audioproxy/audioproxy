## Context

Extracted from `pro-render-priority`: the queue-ordering contract belongs to the OSS package that owns the semaphore, reviewed on its own. The PRO slice (and later upload policies) become pure consumers.

## Goals / Non-Goals

**Goals:**
- Ordered admission that is provably invisible until used; displacement that can never touch an interactive waiter.

**Non-Goals:**
- Any surface that *speaks* a class (warm payload priority — PRO; policy-configured priority — later PRO). OSS ships the mechanism with zero producers.
- Aging/anti-starvation: strict ordering is the contract; starvation of lower classes under sustained higher-class load is intended, visible via per-class depth telemetry, and safe (displaced/starved work is deferred-not-lost — lazy rendering serves any direct request).
- Preemption of running renders: a granted slot runs to completion.

## Decisions

- **Per-class `:queue`s in a small fixed map** inside the existing GenServer — grant scans classes in order; all operations O(1)-ish; eviction is a tail-drop on the lowest class, no scanning, no tombstones. The queue logic stays in the one place the semaphore design already confines it to.
- **`interactive` is the default and not below anything**: nothing can outrank a live listener by construction. It is also never evictable — a listener's patience budget is not sacrificed to a batch.
- **Evict-newest-of-lowest**: the oldest low waiter has waited longest and is closest to running; displacing the entry with the least sunk waiting minimizes wasted intent.
- **Telemetry as a dimension, not new events** — existing occupancy/depth measurements gain `class`; consumers (metrics slice) inherit it label-for-label.

## Risks / Trade-offs

- [Mechanism ships with no OSS producer] → deliberate: the classless-equivalence property test is the proof it costs nothing; the first producer (PRO warm) arrives with its own suite.
- [Displaced-vs-queue-full is a new reply callers must handle] → only class-speaking callers can receive it; classless callers keep the exact old reply surface.
