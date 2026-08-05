## ADDED Requirements

### Requirement: The backlog has a selectable storage backend
The system SHALL retain a render's output either in memory or in a spool file, selected by `AP_BACKLOG_MODE` and defaulting to memory, and the observable stream SHALL be identical either way.

#### Scenario: The same request through both backends
- **WHEN** the same signed request is served in memory mode and in spool mode
- **THEN** the two response bodies are byte-identical

#### Scenario: The default is unchanged
- **WHEN** `AP_BACKLOG_MODE` is unset
- **THEN** the backlog is retained in memory, as every released version has done

### Requirement: Spooled renders do not scale memory with output length
In spool mode the system SHALL write each chunk to a per-cache-key file as it arrives and SHALL NOT retain the accumulated output in process memory, so that a container's resident memory is independent of the length of the variant being produced.

#### Scenario: A long render costs no more memory than a short one
- **WHEN** a full-length lossless render and a thirty-second preview run in spool mode
- **THEN** the coordinator's resident memory for the two is within the same order, rather than differing by the variant sizes

#### Scenario: Retention bounds no longer refuse the workload
- **WHEN** a render whose variant exceeds `AP_MAX_VARIANT_BYTES` runs in spool mode
- **THEN** it is bounded by the spool's own limit rather than by the in-memory retention cap

### Requirement: Late joiners read the spool without racing the writer
A subscriber attaching mid-render SHALL be served the output so far from the spool file, bounded by the offset the coordinator has committed, and SHALL then receive subsequent chunks live. A reader SHALL NOT observe bytes past the committed offset.

#### Scenario: Joining mid-render
- **WHEN** a second request joins a spooled render already in flight
- **THEN** it receives the output so far followed by the remainder, and its concatenation equals the first subscriber's

#### Scenario: No torn chunk at the boundary
- **WHEN** a subscriber attaches while a chunk is being written
- **THEN** it is served only up to the committed offset, and the handover to live chunks introduces no duplicated or missing bytes

#### Scenario: Many simultaneous joiners
- **WHEN** several subscribers join one long spooled render at once
- **THEN** none of them is served a full in-memory copy of the accumulated output

### Requirement: The spool is bounded and reclaimed
The system SHALL bound total spool usage by `AP_SPOOL_MAX_BYTES` and SHALL remove a render's spool file when the render completes, fails, times out, or its coordinator dies. Files left by an unclean shutdown SHALL be removed at startup.

#### Scenario: Completion reclaims
- **WHEN** a spooled render finishes and its linger window closes
- **THEN** its spool file no longer exists

#### Scenario: Failure and timeout reclaim
- **WHEN** a spooled render fails, times out, or its coordinator dies
- **THEN** its spool file no longer exists

#### Scenario: Orphans are swept
- **WHEN** the application starts and the spool directory holds files from a previous run
- **THEN** they are removed before renders begin

#### Scenario: The bound is enforced
- **WHEN** a render would take total spool usage past `AP_SPOOL_MAX_BYTES`
- **THEN** that render fails naming the bound, rather than filling the filesystem
