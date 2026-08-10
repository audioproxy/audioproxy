## ADDED Requirements

### Requirement: Polling helpers have one home
Any test that waits for a condition by polling SHALL use the shared support module rather than defining its own loop.

#### Scenario: A poll loop is needed
- **WHEN** a test must wait for a condition that sends no message when it becomes true
- **THEN** it calls the shared helper, and defines no local `wait_until`, `eventually` or equivalent

#### Scenario: The interval is corrected once
- **WHEN** the polling interval or the failure message is changed in the shared helper
- **THEN** every waiting test carries the change, with no stale duplicate left behind

### Requirement: Waiting distinguishes flunking from reporting
The support layer SHALL offer two distinct waits: one that fails the test when its deadline expires, and one that returns whether the condition held.

#### Scenario: The condition is a precondition
- **WHEN** a test waits for something that must become true for the test to mean anything
- **THEN** expiry fails the test, with a message naming the deadline that was exceeded

#### Scenario: The condition is the assertion
- **WHEN** a test waits for something it intends to assert on, including asserting it does *not* happen
- **THEN** the wait returns a boolean and the test asserts on it

### Requirement: Deadlines stay at the call site
Unifying the poll loop SHALL NOT unify the deadlines.

#### Scenario: A test needs a longer budget
- **WHEN** a test's condition is slower than the default budget allows
- **THEN** it passes its own deadline explicitly, visible where the test is read
