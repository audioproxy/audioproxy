## ADDED Requirements

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
