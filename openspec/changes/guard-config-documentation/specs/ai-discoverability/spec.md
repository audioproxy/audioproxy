## ADDED Requirements

### Requirement: Documented configuration cannot drift from the implementation
The test suite SHALL fail when the set of `AP_`-prefixed environment variables documented in the llms content differs from the set `AudioProxy.Config` reads, in either direction, and the failure SHALL name the variables that differ.

The configuration surface SHALL be published by `AudioProxy.Config` as data, so the check runs against the module's own list rather than a copy of it.

#### Scenario: Variable added without documentation
- **WHEN** `AudioProxy.Config` reads an `AP_`-prefixed variable that the configuration table in `llms-full.txt` does not list
- **THEN** the drift-guard test fails naming the missing variable

#### Scenario: Stale documentation
- **WHEN** the configuration table lists an `AP_`-prefixed variable that `AudioProxy.Config` does not read
- **THEN** the drift-guard test fails naming the stale variable

#### Scenario: The published list cannot itself go stale
- **WHEN** a variable is read by `AudioProxy.Config` but absent from the list it publishes
- **THEN** a test fails, so the seam cannot silently narrow what the guard checks
