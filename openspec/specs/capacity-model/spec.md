# capacity-model Specification

## Purpose
Turns worst-case RAM into arithmetic an operator can do before deploying.
Concurrency, the coalescing backlog cap, the pipeline high-water buffer and the
S3 write-back part buffers are all configured numbers; multiplied by a
measured per-format subprocess cost — and added to ffmpeg's shared library
text, which every concurrent render maps once between them — they give a
container memory limit, rather than a guess adjusted after the first OOM.

Two properties keep the model honest. The per-format ffmpeg constants are
measured on the pinned runtime image and regenerated from a committed script
when the pin moves, so they are evidence rather than assertion. And the model is
a CI check, not a prose claim: a concurrent workload runs against the built
image and fails when observed peak memory exceeds what the model predicts for
that workload's configuration, so a change that grows a memory term has to
reconcile with the document that describes it.

Long-form sources are the case the model exists for. At 1–2 hours the backlog
stops being a rounding error and becomes the dominant term, which makes
lossy full-length output a sizing decision and lossless full-length output
something the cap refuses by design.

## Requirements

### Requirement: A worst-case memory model is published
The system SHALL document worst-case memory as a formula over configuration — concurrency (`AP_MAX_CONCURRENCY`), the backlog cap, the pipeline high-water buffer, S3 write-back part buffers, and measured per-format subprocess RSS — such that an operator can compute a container memory limit from their configuration alone.

#### Scenario: Every term has a knob and a source
- **WHEN** the model's terms are reviewed
- **THEN** each maps to a named configuration variable (or a measured constant with its measurement method) and to the design decision it derives from

#### Scenario: Long-form worked examples
- **WHEN** the documentation is consulted for 1–2 h sources
- **THEN** worked examples cover lossy full-length output (feasible, quantified) and lossless full-length output (fails the backlog cap by design, stated loudly), naming the spooled-backlog escalation as the on-demand path

### Requirement: Subprocess memory is measured, not asserted
The `R_ffmpeg` table SHALL come from measuring peak subprocess memory on the pinned runtime-image ffmpeg across the supported output formats and the heaviest filter path, with the measurement script committed so a pin bump can regenerate it.

The measured quantity SHALL be **anonymous** (private) memory rather than total RSS or cgroup `memory.peak`. Shared library text is mapped once by every concurrent render, so it belongs in a flat term and not in one multiplied by concurrency; and because it is file-backed, including it makes the figure depend on which container happened to fault the pages in — a thirty-fold spread on the same encode, which reads as a finding about the codec and is not one.

#### Scenario: Regenerable on pin bump
- **WHEN** the ffmpeg pin changes
- **THEN** rerunning the committed script reproduces the table for the new binary

#### Scenario: Independent of host cache state
- **WHEN** the same variant is measured on hosts whose page cache differs
- **THEN** the published figure is materially unchanged, because page cache is excluded from it by construction rather than subtracted afterwards

### Requirement: The model is enforced by CI
CI SHALL run a defined concurrent workload (including a long-form fixture) against the built image and fail when observed peak memory exceeds the model's prediction for that workload's configuration, with reclaimable page cache accounted for.

#### Scenario: Model holds
- **WHEN** the workload job runs on a green build
- **THEN** adjusted `memory.peak` is at or under the predicted bound

#### Scenario: Drift is caught
- **WHEN** a change makes a memory term grow beyond the documented model (e.g., a larger part buffer or an uncapped retention path)
- **THEN** the workload job fails, forcing the model and the change to reconcile
