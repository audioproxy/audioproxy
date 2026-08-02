## ADDED Requirements

### Requirement: Admission classes in the wait queue
The semaphore's wait queue SHALL support ordered admission classes: a freed slot goes to the oldest waiter of the highest non-empty class; FIFO holds within a class. Callers that specify no class SHALL receive the highest (`interactive`) class, preserving the pre-classes behavior exactly for all existing callers.

#### Scenario: Class order on release
- **WHEN** a slot frees while waiters of several classes queue
- **THEN** the oldest waiter of the highest non-empty class is granted

#### Scenario: Classless callers unchanged
- **WHEN** only classless (interactive) callers use the semaphore
- **THEN** admission order is indistinguishable from plain FIFO — the classes are invisible until a lower class exists
