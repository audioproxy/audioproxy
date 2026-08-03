## Context

Third `pro-` slice, now a pure consumer: the queue-ordering contract it needs lives in the OSS change `add-semaphore-classes` (extracted so the semaphore's core contract is reviewed in the package that owns it). Everything user-facing rides the already-PRO warm surface.

## Goals / Non-Goals

**Goals:**
- "New episode publishes on time despite a backlog," with listeners never paying for it.

**Non-Goals:**
- Priority on interactive URLs. A `pri:` option would either enter the cache key (identical bytes, multiple keys — the exact violation the options rules exist to prevent) or require inventing a cache-key-exempt option class for one consumer. Recorded as an open question; the need is unproven — interactive requests already outrank everything.
- Aging/anti-starvation. Strict classes are the feature's semantics: a backfill *should* wait while launch-day traffic renders. Deferred-not-lost is the safety property (eviction is reported, lazy render always works).
- Preemption of *running* renders. A slot, once granted, runs to completion — killing a half-done render to free a slot wastes finished work and complicates the no-orphans invariant for nothing (queues clear in render-duration time).

## Decisions

- **Priority is signed or it doesn't exist**: the warm payload is covered by the outer URL signature, so a priority claim is as authorized as the batch itself. Headers were rejected (unsigned); URL options were rejected (cache-key material).
- **Four classes, three exposed**: `interactive` is not spellable in a payload — it is the implicit class of live renders. Warm exposes `high|normal|low`. Nothing outranks a listener, by construction rather than convention.
- **Queue implementation**: the semaphore's single `:queue` becomes one queue per class (a small fixed map) — grant scans classes in order; all operations stay O(1)-ish and, critically, in the one GenServer the semaphore design already confines its queue to. The `add-render-semaphore` slice needs no forward knowledge: this delta layers on its published `acquire/1` by adding an option, defaulting to `interactive`.
- **Evict-newest-of-lowest** on overflow: newest (not oldest) because the oldest low entry has waited longest and is closest to running — displacing the entry with the least sunk waiting minimizes wasted intent. Only warm entries are evictable; interactive waiters never (a listener with a 30 s patience budget must not be sacrificed to a batch).
- **Telemetry as a dimension, not new events**: the semaphore's existing occupancy/depth measurements gain a `class` field — the metrics slice inherits the label without new instrumentation.

## Risks / Trade-offs

- [Strict priority + sustained high load starves normal warms forever] → intended and documented; the eviction report and per-class depth telemetry make it *visible*, which is the operator's actual need.
- [Class-aware eviction adds queue-removal mid-structure] → per-class queues make eviction a tail-drop on the lowest class — no scanning, no marker tombstones.
- [Core delta lands before any PRO consumer exists if slices reorder] → harmless: classless callers are spec'd to behave exactly as plain FIFO; the delta is invisible until a consumer speaks a class.
