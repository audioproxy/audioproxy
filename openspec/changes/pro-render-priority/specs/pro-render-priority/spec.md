## ADDED Requirements

### Requirement: Warm entries carry a priority
Warm batch payloads SHALL accept a `priority` of `high`, `normal` (default), or `low`, per entry or per batch (entry overrides batch); an unknown priority value SHALL invalidate only that entry.

#### Scenario: Episode jumps the backfill
- **WHEN** a `low` backfill batch fills the queue and a `high` entry arrives
- **THEN** the `high` entry is admitted to a render slot before any queued `low` entry

#### Scenario: Default is normal
- **WHEN** an entry carries no priority
- **THEN** it queues as `normal`

### Requirement: Class ordering with interactive supremacy
The render queue SHALL admit strictly by class — `interactive` > `high` > `normal` > `low` — with FIFO order inside each class. Live render requests are always `interactive`; no warm priority can delay a listener.

#### Scenario: Interactive beats high
- **WHEN** the queue holds `high` warm entries and a live GET render arrives
- **THEN** the live render is admitted first

#### Scenario: FIFO within class
- **WHEN** two `high` entries queue in order A then B
- **THEN** A is admitted before B

#### Scenario: Starvation is the contract
- **WHEN** `high` entries keep arriving faster than slots free
- **THEN** `normal`/`low` entries wait indefinitely — deferred, never lost: they remain queued or are evicted with an explicit `rejected` report, and lazy rendering still serves any direct request for them

### Requirement: Priority-aware overflow
When the wait queue is full, an arriving entry of a higher class SHALL displace the most recently queued entry of the lowest class present (reported `rejected`, retryable) instead of being refused; interactive entries SHALL never be displaced; an arrival not outranking anything queued is refused as today.

#### Scenario: Eviction on overflow
- **WHEN** the queue is full of `low` entries and a `high` entry arrives
- **THEN** the newest `low` entry is reported `rejected` and the `high` entry queues

#### Scenario: No rank, no eviction
- **WHEN** the queue is full of `high` entries and a `normal` entry arrives
- **THEN** the arrival is refused (queue-full), nothing is evicted

### Requirement: Class-labeled observability
Queue telemetry SHALL carry the class dimension (depth per class, admissions, evictions), so operators can see a backlog and what outranks it.

#### Scenario: Depth per class
- **WHEN** entries of several classes are queued
- **THEN** telemetry reports per-class depths, not a single aggregate
