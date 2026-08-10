# test-support Specification

## Purpose
What `test/support/` owns, and what a test file is therefore not allowed to
define for itself.

The suite has repeatedly grown another copy of something that already existed —
a poll loop, a listener boot, a signing preamble — because the next author
needed one and wrote one rather than finding the ones already in the tree. The
poll loop reached seventeen copies, under four names, before anyone counted.
The copies then drift, and the drift hides the one distinction that mattered:
of those seventeen, some flunked on expiry and some returned a boolean, and
which was which was legible only from the file you happened to be reading.

So the rule is about *where a thing lives*, not merely about repetition: when a
helper carries a reason (why a config value is pinned, why a deadline is what it
is), that reason has to live with the helper, because the files that depend on
it will not carry it and a reader tidying one of them will not find it.

## Requirements
### Requirement: Test key material has one home
The suite's signing key and salt SHALL be defined once in the support layer and referenced by every test that signs a URL.

#### Scenario: A test needs to sign a request
- **WHEN** a test builds a signed path
- **THEN** it takes the key and salt from the support layer and defines no literal of its own

#### Scenario: The material is not mistaken for a secret
- **WHEN** a reader or a scanner encounters the key material
- **THEN** the file states that it is a fixed test vector, never loaded by `lib/` and never an operational default

### Requirement: The config floor is stated once, with its reason
The configuration values that exist to make tests independent of the developer's environment SHALL be supplied by one helper, together with the explanation of what they are defending against.

#### Scenario: A limit is set in the environment
- **WHEN** a developer has `AP_MAX_SRC_BYTES` or a similar variable set in their shell
- **THEN** tests that assert on unrelated statuses still pass, because the floor pins the values the chain reads

#### Scenario: Someone tidies the floor
- **WHEN** a reader wonders why the floor pins a limit no test appears to need
- **THEN** the answer is attached to the helper, not to one of the eighteen files that depend on it

### Requirement: Per-file config stays visible
The shared floor SHALL be overridable per test file, and a value a test is about SHALL be visible at that file's call site.

#### Scenario: A file tests a timeout
- **WHEN** a test file needs a short probe or render timeout to make its point
- **THEN** that value appears in that file's setup, merged over the floor rather than hidden inside it

#### Scenario: The local root is per test
- **WHEN** a test file supplies its config
- **THEN** it must name its own local root; the helper does not default one

### Requirement: The signed-path grammar is implemented once in the suite
The construction of a signed path from a request remainder SHALL exist in one place in the test support layer.

#### Scenario: The URL grammar changes
- **WHEN** the signed-path grammar in the API contract changes
- **THEN** one test-support function changes, and every signing test follows

#### Scenario: The suite disagrees with production
- **WHEN** the test helper's construction and the production implementation diverge
- **THEN** tests fail, because the helper is deliberately an independent implementation rather than a call into production code

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

