# test-support Specification

## Purpose
What `test/support/` owns, and what a test file is therefore not allowed to
define for itself.

The suite has repeatedly grown its tenth copy of something that already existed
— a poll loop, a listener boot, a signing preamble — because the fourteenth
author needed one and wrote one rather than finding the thirteen in the tree.
The copies then drift, and the drift hides the one distinction that mattered.

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

