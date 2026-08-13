## ADDED Requirements

### Requirement: The signed chain has one mounting
The system SHALL mount the checks every signed request passes before its action — signature verification, option parsing, expiry, source resolution — from a single shared unit that the production pipeline and every test pipeline compose, so that a check added to the chain reaches the deployed request path and the test mountings together and cannot be present in one while absent from another.

#### Scenario: A check cannot be mounted in the tests but not in production
- **WHEN** a plug is added to or removed from the shared unit
- **THEN** the production pipeline and every test pipeline change with it, and no hand-copied plug list exists that could disagree

#### Scenario: Removing a check fails the suite
- **WHEN** any plug is removed from the shared unit
- **THEN** the existing suite fails, because the tests exercise the same mounting the deployment runs

#### Scenario: Behaviour is unchanged
- **WHEN** the refactor lands
- **THEN** the request path is observably identical — the suite passes with no test edits, which is what demonstrates it
