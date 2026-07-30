## ADDED Requirements

### Requirement: Subprocess output streams as chunks
The system SHALL execute a render as a subprocess from an argv list (never a shell string) and deliver its stdout to the consumer as an ordered stream of binary chunks followed by a completion message.

#### Scenario: Byte fidelity
- **WHEN** a subprocess emits a known byte sequence
- **THEN** the concatenated chunks received equal that sequence exactly, followed by `{:done, exit_info}`

#### Scenario: Argv execution
- **WHEN** the command contains shell metacharacters as argument values
- **THEN** they arrive in the subprocess argv verbatim (no shell interpretation)

### Requirement: No orphan processes
The system SHALL terminate the subprocess (SIGKILL after grace) whenever the consumer dies, the render is cancelled, or the owning process exits — under no circumstance may an ffmpeg process outlive its render.

#### Scenario: Consumer dies mid-stream
- **WHEN** the consumer process exits while the subprocess is still producing
- **THEN** the OS process is dead within the grace period (asserted by PID probe)

#### Scenario: Cancel API
- **WHEN** `cancel/1` is called on a running render
- **THEN** the subprocess is terminated and the consumer receives a cancellation message

### Requirement: Render timeout enforced
The system SHALL kill renders exceeding `AP_RENDER_TIMEOUT` and report a timeout error distinct from other failures (HTTP layer maps it to 504).

#### Scenario: Hanging subprocess
- **WHEN** the subprocess produces no exit within the configured timeout
- **THEN** it is killed and the consumer receives `{:error, :timeout}`

### Requirement: Failure classification
The system SHALL capture exit status and a bounded stderr tail, classifying failures so the HTTP layer can map them: unreadable/nonexistent input (404), undecodable input (415), timeout (504), other (500-class).

#### Scenario: Nonzero exit with diagnostics
- **WHEN** the subprocess exits nonzero after emitting stderr output
- **THEN** the consumer receives an error containing the exit code, a classification, and the stderr tail (truncated to a fixed byte budget)

#### Scenario: Real decode failure (integration)
- **WHEN** ffmpeg is given a non-audio input file
- **THEN** the failure classifies as undecodable
