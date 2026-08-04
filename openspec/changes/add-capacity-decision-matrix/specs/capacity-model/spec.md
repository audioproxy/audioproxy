## ADDED Requirements

### Requirement: The concurrency decision is answered before the model is explained
The capacity documentation SHALL open with a matrix giving maximum safe `AP_MAX_CONCURRENCY` as a function of output length, codec/bitrate and container memory limit, positioned ahead of the formula, the term table and the measured constants.

#### Scenario: An operator sizes a host without arithmetic
- **WHEN** an operator with a known host size and a known workload consults the documentation
- **THEN** a concurrency figure is readable from a table within the first screen, without evaluating the formula

#### Scenario: The derivation remains available
- **WHEN** a reader wants to know where a cell came from
- **THEN** the formula, the per-term mapping and the measured `R_ffmpeg` table follow the matrix and account for it

### Requirement: Matrix cells are generated from the enforced model
Every cell SHALL be computed from the published formula and the committed measured table by a script, not maintained by hand, so that the matrix cannot disagree with the model CI enforces.

#### Scenario: Regenerated with the constants
- **WHEN** the measured table is regenerated or a model constant changes
- **THEN** rerunning the generator reproduces the matrix for the new values

### Requirement: Unservable workloads are shown as refusals
A workload whose single-render backlog exceeds `AP_MAX_SRC_BYTES` SHALL be marked as refused rather than assigned a concurrency figure.

#### Scenario: Full-length lossless
- **WHEN** the matrix is consulted for a 2 h `f:wav/bd:24` output against the default retention cap
- **THEN** the cell states that the render exceeds the cap and refers to the lossless section, rather than reporting a concurrency of 1

### Requirement: Knobs that do not affect the bound say so
The documentation SHALL state which adjustable variables are absent from the matrix and why — specifically that `AP_QUEUE_SIZE` costs no meaningful memory because a queued render holds neither backlog nor subprocess, and that `AP_MAX_SRC_BYTES` bounds a single render rather than the total.

#### Scenario: An operator tunes the queue for memory
- **WHEN** the documentation is consulted about `AP_QUEUE_SIZE`
- **THEN** it states that the queue is a latency and `429` decision rather than a memory one
