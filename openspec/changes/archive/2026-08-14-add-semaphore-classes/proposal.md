## Why

The render semaphore's wait queue is strictly FIFO. Several foreseeable consumers want ordered admission instead — background/batch work that must yield to interactive renders (cache warming, upload-policy eager renders, priority tiers), all sharing one contract: a freed slot goes to the oldest waiter of the highest non-empty class, and callers that say nothing behave exactly as today. That invisibility is what makes this neutral core rather than a feature: until a caller speaks a class, the classes do not exist. Extracted from `pro-render-priority` so the core contract lives (and is reviewed) in the OSS package its semaphore belongs to.

## What Changes

- `acquire/1` gains a `class:` option — ordered admission classes (`interactive` highest and default, then `high > normal > low`), FIFO within a class.
- Class-aware overflow: when the queue is full, an arriving entry of a higher class displaces the newest waiter of the lowest non-`interactive` class present (distinct reply, retryable); `interactive` waiters are never displaced; an arrival outranking nothing is refused as today.
- Telemetry measurements gain a `class` dimension (depth per class, admissions, evictions) — the metrics slice inherits the label.
- No behavior change for existing callers, property-tested: classless-only traffic is indistinguishable from plain FIFO.

## Capabilities

### New Capabilities

<!-- none -->

### Modified Capabilities

- `render-concurrency`: the wait queue SHALL support ordered admission classes with FIFO inside each class, invisible to classless callers.

## Impact

- Modified: `AudioProxy.Semaphore` (per-class queues in the existing GenServer), its telemetry measurements.
- Depends on: merged code only.
- Consumers: none in OSS today — first consumers are the PRO warm/priority track and, later, upload policies. Position: on demand, implemented when the first consumer is ready; harmless earlier.
