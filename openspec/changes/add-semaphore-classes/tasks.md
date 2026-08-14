## 1. Classes

- [x] 1.1 Per-class wait queues in `AudioProxy.Semaphore`; `acquire/1` `class:` option defaulting to `interactive`; grant = oldest waiter of highest non-empty class
- [x] 1.2 Class-aware overflow: displace newest waiter of the lowest non-interactive class when outranked; distinct retryable reply; interactive never displaced
- [x] 1.3 Telemetry: `class` dimension on depth/admission/displacement measurements

## 2. Tests

- [x] 2.1 Class order on release; FIFO within class; displacement scenarios; no-rank refusal
- [x] 2.2 Property: classless-only workloads are indistinguishable from the pre-classes semaphore (model comparison)
- [x] 2.3 Crash-safety per class: holder/waiter DOWN handling unchanged; displaced waiters leave no monitors behind

## 3. Docs

- [x] 3.1 `docs/rendering.md`: admission classes, displacement, and the starvation-is-intended contract; README concurrency section gains one line (classes exist; nothing in OSS sets them yet)
