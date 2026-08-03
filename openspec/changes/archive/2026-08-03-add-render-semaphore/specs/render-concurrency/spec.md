## ADDED Requirements

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
