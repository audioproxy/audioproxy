## MODIFIED Requirements

### Requirement: Documented configuration cannot drift from the implementation
The test suite SHALL fail when the set of `AP_`-prefixed environment variables documented in the llms content differs from the set `AudioProxy.Config` reads, in either direction, and the failure SHALL name the variables that differ.

The configuration surface SHALL be published by `AudioProxy.Config` as data, so the check runs against the module's own list rather than a copy of it.

Variable *names* are compared, not their default values: several defaults are derived rather than literal, and the document renders them for a reader rather than for a comparison.

`llms-full.txt` SHALL be the one guarded copy. The configuration surface is documented for operators on the documentation site, which is not machine-checked against this repository; a second guarded copy in `README.md` existed only because the README carried the same table, and it does not anymore.

#### Scenario: Variable added without documentation
- **WHEN** `AudioProxy.Config` reads an `AP_`-prefixed variable that the configuration table in `llms-full.txt` does not list
- **THEN** the drift-guard test fails naming the missing variable

#### Scenario: Stale documentation
- **WHEN** the configuration table lists an `AP_`-prefixed variable that `AudioProxy.Config` does not read
- **THEN** the drift-guard test fails naming the stale variable

#### Scenario: The published list cannot itself go stale
- **WHEN** a variable is read by `AudioProxy.Config` but absent from the list it publishes
- **THEN** a test fails, so the seam cannot silently narrow what the guard checks

#### Scenario: A read that moves out of the recognised shape cannot be trimmed away
- **WHEN** a variable's read moves to a form the call-site scan does not recognise — a module attribute, a helper whose first argument is named differently — and the variable is then removed from the published list to make that failure go away
- **THEN** a test still fails, because the variable's name remains written in the module as a string literal, and the failure names the variable rather than accepting the narrower list

#### Scenario: The README carries no configuration table to guard
- **WHEN** the drift-guard suite runs
- **THEN** it reads the configuration surface from `llms-full.txt` only, and no test parses `README.md`
