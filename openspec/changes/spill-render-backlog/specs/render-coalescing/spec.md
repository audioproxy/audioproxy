## ADDED Requirements

### Requirement: The backlog spills by size
A render SHALL retain its backlog in memory until it exceeds `AP_BACKLOG_SPILL_BYTES`, then write what it holds to a spool file and continue there for the remainder of the render, so that the storage choice follows the workload rather than configuration.

#### Scenario: Preview-shaped renders never touch disk
- **WHEN** a render's total output stays below the threshold
- **THEN** no spool file is created for it

#### Scenario: Long-form spills without configuration
- **WHEN** a render's output crosses the threshold
- **THEN** the backlog moves to a spool file and memory use stops tracking output length

#### Scenario: The transition preserves the stream
- **WHEN** subscribers attach before the spill, during it, and after it
- **THEN** every subscriber receives a byte-identical complete stream

### Requirement: A failed spill fails the render
If writing the spill or any subsequent chunk fails, the render SHALL fail rather than reverting to memory, so that no two subscribers of one render are ever served from different backing stores.

#### Scenario: Write failure is terminal
- **WHEN** the spool write fails mid-render
- **THEN** the render fails and its subscribers receive the error, with no silent fallback
