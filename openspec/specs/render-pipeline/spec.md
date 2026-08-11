# render-pipeline Specification

## Purpose
Running ffmpeg as a supervised subprocess and turning its stdout into a chunk
stream, which is the seam every other capability is written against. Coalescing
subscribes several requests to one render's chunks, chunked delivery and the S3
write-back both consume them, and `/info` reuses the same plumbing for
`ffprobe` — none of them knowing what ffmpeg is. The subprocess boundary is
also the licensing boundary: invoking a CLI keeps even a GPL-configured ffmpeg
out of this source tree.

Two guarantees make that seam safe to build on. **No ffmpeg process outlives
its render** — a clean finish, a cancel, a timeout, a dead consumer and the
supervisor's own shutdown all end in the same teardown, because closing a port
does not signal the process on the far side of it, and an encoder that never
notices is an orphan holding a CPU slot. And **a failure says what kind it
was**: ffmpeg exits 1 for nearly everything, so a bounded tail of its stderr is
what separates a missing source from an undecodable one, and therefore what
lets the HTTP layer answer 404 or 415 rather than 500 for all of it.

Output is bounded rather than truly back-pressured. Ports have no passive read
mode, so the render counts unacknowledged bytes and stops forwarding above a
high-water mark; ffmpeg then blocks on the OS pipe. That is sufficient for the
preview-sized renders this proxy is built for, and the named-pipe escalation
that would make it real backpressure changes the mechanism without changing the
contract above.
## Requirements
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
- **THEN** it is killed and the consumer receives a failure classified `:timeout`, distinct from every other failure class

### Requirement: Failure classification
The system SHALL capture exit status and a bounded stderr tail, classifying failures so the HTTP layer can map them: unreadable/nonexistent input (404), undecodable input (415), timeout (504), other (500-class).

#### Scenario: Nonzero exit with diagnostics
- **WHEN** the subprocess exits nonzero after emitting stderr output
- **THEN** the consumer receives an error containing the exit code, a classification, and the stderr tail (truncated to a fixed byte budget)

#### Scenario: Real decode failure (integration)
- **WHEN** ffmpeg is given a non-audio input file
- **THEN** the failure classifies as undecodable

### Requirement: Render scratch is isolated per instance
Two instances running on one host SHALL NOT share the directory their renders' stderr files are written to, whether or not either is a distributed node.

#### Scenario: Two undistributed VMs on one host
- **WHEN** two instances start on the same host, neither given a node name, and both resolve the scratch directory
- **THEN** the two directories differ

#### Scenario: A failure is classified while another instance boots
- **WHEN** an instance boots and performs its scratch sweep while a render in another instance is running
- **THEN** that render's stderr file still exists when its failure is classified, so the failure keeps its class rather than degrading to the unclassified one

### Requirement: The boot sweep reclaims only orphans
The boot sweep SHALL remove scratch belonging to instances that are no longer running, and SHALL NOT remove scratch belonging to a running instance.

#### Scenario: An instance was killed without cleanup
- **WHEN** an instance dies to `kill -9`, an OOM kill or a container crash, leaving stderr files behind, and a later instance boots
- **THEN** the dead instance's files are removed

#### Scenario: Ownership cannot be established
- **WHEN** the sweep cannot determine that the owner of some scratch is gone
- **THEN** it leaves that scratch alone, preferring to reclaim it at a later boot over deleting a file that may be in use

