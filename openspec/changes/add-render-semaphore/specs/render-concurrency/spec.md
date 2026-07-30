## ADDED Requirements

### Requirement: Concurrency is capped
The system SHALL never allow more than `AP_MAX_CONCURRENCY` concurrently held render slots (default: schedulers online).

#### Scenario: Cap enforced under load
- **WHEN** 3× the cap of concurrent acquirers race
- **THEN** at no instant do more than the cap hold slots, and all acquirers eventually run or overflow

### Requirement: Bounded FIFO wait queue
The system SHALL queue up to `AP_QUEUE_SIZE` waiting acquirers in FIFO order and reject further acquirers immediately with a queue-full error.

#### Scenario: Queueing
- **WHEN** all slots are held and a new acquirer arrives with queue space free
- **THEN** it waits, and acquires when a slot is released, in arrival order

#### Scenario: Overflow
- **WHEN** all slots are held and the queue is full
- **THEN** a new acquirer receives `{:error, :queue_full}` without waiting (HTTP layer maps to 429 with `Retry-After`)

### Requirement: Crash-safe release
The system SHALL release a slot when its holder exits for any reason, and SHALL remove waiting acquirers that die before being granted a slot.

#### Scenario: Holder crashes
- **WHEN** a process holding a slot exits abnormally
- **THEN** the slot is released and granted to the next waiter

#### Scenario: Waiter abandons
- **WHEN** a queued process exits before acquiring
- **THEN** it is removed from the queue and never granted a slot
