## ADDED Requirements

### Requirement: A wait may hand back what it waited for
The support layer SHALL cover the poll whose result is a value rather than a verdict, so that a test needing one does not write its own loop.

#### Scenario: The value is the point of the wait

- **WHEN** a test polls until something exists — a scrape body that matches, a
  restarted process's pid — and then asserts on that thing
- **THEN** the wait returns it directly, and the test does not re-read it
  afterwards

#### Scenario: Re-reading would reopen the race

- **WHEN** a value can change again between the wait succeeding and a separate
  read of it
- **THEN** the test is not required to perform that separate read, because the
  wait already carries the value it observed

### Requirement: A value wait keeps its diagnostic
Replacing a private value-returning loop SHALL NOT cost the failure message that made it debuggable.

#### Scenario: The condition never holds

- **WHEN** a value wait expires without its condition ever holding
- **THEN** the failure names both the deadline and what the test last observed,
  where the observation is what identifies the fault
