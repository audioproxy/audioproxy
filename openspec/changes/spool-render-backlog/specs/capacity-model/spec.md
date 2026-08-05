## ADDED Requirements

### Requirement: The model states which backlog architecture it describes
The capacity documentation SHALL publish a memory model per backlog mode: with `B_backlog` in the per-render bracket for memory mode, and without it for spool mode, where the per-render cost is the ffmpeg subprocess and the pipeline buffer alone.

The existing version banner already scopes the page to the in-memory architecture; it SHALL name the mode rather than the version once both exist.

#### Scenario: Spool mode drops the dominant term
- **WHEN** the model is read for spool mode
- **THEN** the per-render bracket is `R_ffmpeg + H_pipeline`, and output length does not appear in the memory arithmetic

#### Scenario: The matrix reflects the mode
- **WHEN** the decision matrix is generated for spool mode
- **THEN** workloads marked **refused** under the in-memory model are no longer refused for memory reasons, and concurrency is bounded by the flat terms and by CPU

### Requirement: Spool disk is a sized resource
The documentation SHALL give the disk a spooled deployment needs — approximately concurrency × variant size — and SHALL state that a memory-backed filesystem for the spool reinstates the memory cost while appearing to remove it.

#### Scenario: Disk sizing is answerable
- **WHEN** an operator sizes a spooled deployment
- **THEN** the documentation gives the spool requirement as arithmetic over concurrency and variant size, in the same shape as the memory model

#### Scenario: The tmpfs trap is named
- **WHEN** the documentation is consulted about where to put the spool
- **THEN** it states that a tmpfs or other memory-backed mount puts the bytes back in RAM, so the configuration that looks like it works is the one that has not fixed anything
