# render-concurrency Specification

## Purpose
Ration the one resource a transcoding proxy actually runs out of: concurrently
running encoders. At most `AP_MAX_CONCURRENCY` renders hold a slot, with a
bounded FIFO queue of `AP_QUEUE_SIZE` behind them and an immediate rejection
past that, so a burst queues and then sheds rather than thrashing the box. A
slot counts a *render* — coalesced requests share one, a cache hit needs none,
and a slot is given back the moment its encoder is finished rather than when
the process holding it stops. Slots are recovered by monitor, so a crash costs
one only for as long as the monitor takes to fire.
## Requirements
### Requirement: Concurrency is capped
The system SHALL never allow more than `AP_MAX_CONCURRENCY` concurrently held render slots (default: schedulers online).

#### Scenario: Cap enforced under load
- **WHEN** 3× the cap of concurrent acquirers race
- **THEN** at no instant do more than the cap hold slots, and all acquirers eventually run or overflow

#### Scenario: Coalesced requests share one slot
- **WHEN** several concurrent requests coalesce onto a single render
- **THEN** they hold one slot between them, so the cap counts renders and not requests

#### Scenario: A cache hit needs no slot
- **WHEN** every slot is held, the queue is full, and a request's variant is already in the variant store
- **THEN** it is served from the store without acquiring a slot and without being rejected

### Requirement: Bounded FIFO wait queue
The system SHALL queue up to `AP_QUEUE_SIZE` waiting acquirers in FIFO order and reject further acquirers immediately with a queue-full error.

#### Scenario: Queueing
- **WHEN** all slots are held and a new acquirer arrives with queue space free
- **THEN** it waits, and acquires when a slot is released, in arrival order

#### Scenario: Overflow
- **WHEN** all slots are held and the queue is full
- **THEN** a new acquirer receives `{:error, :queue_full}` without waiting (HTTP layer maps to 429 with `Retry-After`)

#### Scenario: A wait that runs out of budget
- **WHEN** an acquirer is queued and no slot reaches it within the requesting layer's budget (`AP_RENDER_TIMEOUT`)
- **THEN** it stops waiting and is answered the same 429 with `Retry-After` as an overflow — never a render timeout, since no render ran

### Requirement: A slot lasts as long as the render, not as long as its holder
The system SHALL release a render slot once its render has finished, before any period in which the completed output is only being served from memory.

#### Scenario: Completed render still serving late subscribers
- **WHEN** a render completes and its coordinator stays available so a request that arrives moments later gets the finished bytes
- **THEN** its slot has already been released and is available to the next waiter

### Requirement: Crash-safe release
The system SHALL release a slot when its holder exits for any reason, and SHALL remove waiting acquirers that die before being granted a slot.

#### Scenario: Holder crashes
- **WHEN** a process holding a slot exits abnormally
- **THEN** the slot is released and granted to the next waiter

#### Scenario: Waiter abandons
- **WHEN** a queued process exits before acquiring
- **THEN** it is removed from the queue and never granted a slot

### Requirement: Concurrent probes have a ceiling
The system SHALL bound the number of concurrently running source probes, independently of the render slot cap. The bound SHALL NOT be the render semaphore: a probe must never wait behind an encoder, since the endpoint a client calls before it knows what to request would otherwise be the slowest path in the proxy.

Overflow SHALL answer 429 with `Retry-After`, through the same error the render queue produces when it is full.

#### Scenario: The probe ceiling holds under load
- **WHEN** 3× the probe bound's worth of concurrent requests for distinct sources arrive
- **THEN** at no instant do more than the bound have a probe running, and every request either probes or is shed with 429

#### Scenario: A probe never queues behind a render
- **WHEN** every render slot is held and the render queue is full
- **THEN** a probe still runs, bounded only by its own ceiling

#### Scenario: A cache hit needs neither
- **WHEN** the probe bound is exhausted and a request's variant is already in the variant store
- **THEN** it is served from the store without probing and without being shed

### Requirement: Admission classes in the wait queue
The semaphore's wait queue SHALL support ordered admission classes (`interactive > high > normal > low`): a freed slot goes to the oldest waiter of the highest non-empty class; FIFO holds within a class. Callers that specify no class SHALL receive `interactive`, preserving pre-classes behavior exactly for all existing callers.

#### Scenario: Class order on release
- **WHEN** a slot frees while waiters of several classes queue
- **THEN** the oldest waiter of the highest non-empty class is granted

#### Scenario: FIFO within class
- **WHEN** two same-class waiters queue in order A then B
- **THEN** A is granted before B

#### Scenario: Classless callers unchanged
- **WHEN** only classless callers use the semaphore
- **THEN** admission order is indistinguishable from plain FIFO

### Requirement: Class-aware overflow
When the wait queue is full, an arriving waiter of a higher class SHALL displace the most recently queued waiter of the lowest non-`interactive` class present, with a reply distinct from queue-full (retryable); `interactive` waiters SHALL never be displaced; an arrival that outranks nothing queued SHALL be refused as today.

#### Scenario: Eviction on overflow
- **WHEN** the queue is full of `low` waiters and a `high` waiter arrives
- **THEN** the newest `low` waiter receives the displaced reply and the `high` waiter queues

#### Scenario: No rank, no eviction
- **WHEN** the queue is full of `high` waiters and a `normal` waiter arrives
- **THEN** the arrival is refused (queue-full) and nothing is displaced

### Requirement: Class-labeled queue telemetry
The semaphore's telemetry SHALL carry the class dimension: depth per class, admissions, and displacements.

#### Scenario: Depth per class
- **WHEN** waiters of several classes queue
- **THEN** telemetry reports per-class depths, not a single aggregate

