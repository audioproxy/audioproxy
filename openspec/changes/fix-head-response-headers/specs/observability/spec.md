## MODIFIED Requirements

### Requirement: Queue and cache metrics
The system SHALL export semaphore occupancy and queue depth as gauges, alongside the capacities they are measured against, a counter of requests the semaphore refused for want of queue room, cache outcome counters (hit, miss, coalesced), and a counter of variant-store write-back failures.

The occupancy and depth gauges SHALL be sampled when scraped rather than accumulated from events, so that they cannot drift from the semaphore's own state.

The rejection counter counts *semaphore* rejections. A request answered `429` because it waited for a slot until its deadline expired is not one, so this counter is a lower bound on `429`s rather than a count of them.

The cache outcome counters count requests that were **delivered** a variant, so a `HEAD` SHALL NOT increment them even though it now reports a verdict in `X-Audio-Proxy`. Reporting and counting are deliberately separated here: a probe is cheap precisely because it delivers nothing, and counting one would let probe traffic move a ratio that describes serving. Counting only the hit side, which is where the store lookup happens, would be worse still — the numerator would take traffic the denominator refuses.

#### Scenario: Cache outcomes tracked
- **WHEN** a MISS, a HIT, and a COALESCED request occur
- **THEN** each increments its respective counter

#### Scenario: Only delivered responses counted
- **WHEN** a request is answered without delivering a variant — a `304`, a `429`, or a `HEAD` in either of its shapes
- **THEN** no cache outcome counter increments, so the hit ratio's denominator is requests that were actually served

#### Scenario: Probing cannot move the hit ratio
- **WHEN** a `HEAD` is answered from the variant store
- **THEN** the hit counter is unchanged, so a client polling `HEAD` cannot inflate the ratio

#### Scenario: Rejection tracked
- **WHEN** the semaphore refuses a request because the wait queue was full
- **THEN** the rejection counter increments

#### Scenario: Silent cache failure is visible
- **WHEN** a completed render cannot be written back to the variant store
- **THEN** the write-failure counter increments, even though every client was served
