## ADDED Requirements

### Requirement: Gating jobs gate merges, not only tags
Every CI job that gates publishing SHALL also appear in the documented set of checks required to merge, so that a commit which could not be published cannot reach `main` either.

#### Scenario: A gating job is red on a pull request
- **WHEN** a job that gates publishing fails on a pull request
- **THEN** that pull request cannot merge

#### Scenario: A deliberately advisory job
- **WHEN** a job gates publishing but is deliberately not required to merge
- **THEN** the documented set records it and the reason, rather than omitting it silently

### Requirement: The documented check list is verified against the workflow
The documented set of required checks SHALL be compared against the job names the workflow actually produces, with each matrix job expanded per leg, and SHALL fail on disagreement in either direction.

#### Scenario: A job is renamed
- **WHEN** a gating job's name changes, including by gaining a matrix leg
- **THEN** the guard fails until the documented set is updated

#### Scenario: A documented check no longer exists
- **WHEN** the documented set names a check the workflow no longer produces
- **THEN** the guard fails, rather than leaving a rule that blocks every pull request forever
