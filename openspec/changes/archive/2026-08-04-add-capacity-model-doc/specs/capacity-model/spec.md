## ADDED Requirements

### Requirement: A worst-case memory model is published
The system SHALL document worst-case memory as a formula over configuration — concurrency (`AP_MAX_CONCURRENCY`), the backlog cap, the pipeline high-water buffer, S3 write-back part buffers, and measured per-format subprocess RSS — such that an operator can compute a container memory limit from their configuration alone.

#### Scenario: Every term has a knob and a source
- **WHEN** the model's terms are reviewed
- **THEN** each maps to a named configuration variable (or a measured constant with its measurement method) and to the design decision it derives from

#### Scenario: Long-form worked examples
- **WHEN** the documentation is consulted for 1–2 h sources
- **THEN** worked examples cover lossy full-length output (feasible, quantified) and lossless full-length output (fails the backlog cap by design, stated loudly), naming the spooled-backlog escalation as the on-demand path

### Requirement: Subprocess memory is measured, not asserted
The `R_ffmpeg` table SHALL come from measuring peak subprocess RSS on the pinned runtime-image ffmpeg across the supported output formats and the heaviest filter path, with the measurement script committed so a pin bump can regenerate it.

#### Scenario: Regenerable on pin bump
- **WHEN** the ffmpeg pin changes
- **THEN** rerunning the committed script reproduces the table for the new binary

### Requirement: The model is enforced by CI
CI SHALL run a defined concurrent workload (including a long-form fixture) against the built image and fail when observed peak memory exceeds the model's prediction for that workload's configuration, with reclaimable page cache accounted for.

#### Scenario: Model holds
- **WHEN** the workload job runs on a green build
- **THEN** adjusted `memory.peak` is at or under the predicted bound

#### Scenario: Drift is caught
- **WHEN** a change makes a memory term grow beyond the documented model (e.g., a larger part buffer or an uncapped retention path)
- **THEN** the workload job fails, forcing the model and the change to reconcile
