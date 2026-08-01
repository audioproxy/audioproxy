## ADDED Requirements

### Requirement: Local source form
The system SHALL register a `local` source type accepting `local://{path}` in both `plain/` and `enc/` encodings, yielding a typed local source whose canonical identity is `local://` plus the decoded, root-relative path.

#### Scenario: Local form parses
- **WHEN** parsing `plain/local://previews/track.wav`
- **THEN** the result is a local source with relative path `previews/track.wav`

#### Scenario: Encoding equivalence holds for local
- **WHEN** the same local source arrives via `plain` and `enc` forms
- **THEN** both yield the same typed source and byte-identical canonical strings

#### Scenario: Cache identity is root-independent
- **WHEN** the same relative path is served under different `AP_LOCAL_ROOT` values
- **THEN** the canonical source string (and thus the cache key) is unchanged — the root is deployment config, not source identity

### Requirement: Local sources resolve against a configured root
The system SHALL serve sources of the form `local://{path}` from beneath the directory configured in `AP_LOCAL_ROOT`; when `AP_LOCAL_ROOT` is unset, local sources SHALL be rejected as unauthorized (404).

#### Scenario: Local source renders
- **WHEN** `AP_LOCAL_ROOT=/data` and a render is requested for `local://fixtures/tone.wav` with `/data/fixtures/tone.wav` present
- **THEN** the render proceeds with that file as ffmpeg's input

#### Scenario: Local disabled by default
- **WHEN** `AP_LOCAL_ROOT` is unset
- **THEN** any `local://` source is rejected with 404

### Requirement: Path confinement
The system SHALL confine resolved local paths to the configured root: traversal segments (`..`, encoded variants), absolute paths, null bytes, and symlinks escaping the root SHALL all be rejected with 404, never resolved.

#### Scenario: Dot-dot traversal
- **WHEN** the source is `local://../etc/passwd` (or a percent-encoded spelling)
- **THEN** the response is 404 and no filesystem access outside the root occurs

#### Scenario: Symlink escape
- **WHEN** a file inside the root is a symlink targeting outside the root
- **THEN** the source is rejected with 404

#### Scenario: Property — confinement is total
- **WHEN** resolving randomly generated hostile path strings (property test)
- **THEN** every accepted path's canonical form has the root as a prefix

### Requirement: Stat-based source metadata
The system SHALL derive existence and size from the filesystem for local sources: missing/unreadable → 404; size above `AP_MAX_SRC_BYTES` → 413; regular files only (directories, devices, sockets → 404).

#### Scenario: Missing file
- **WHEN** the resolved path does not exist
- **THEN** the response is 404

#### Scenario: Oversized file
- **WHEN** the file's size exceeds `AP_MAX_SRC_BYTES`
- **THEN** the response is 413 without starting a render

#### Scenario: Non-regular file
- **WHEN** the resolved path is a directory or FIFO
- **THEN** the response is 404

### Requirement: Storage seam
The system SHALL access source metadata and ffmpeg input through one storage seam (stat + input handoff per resolved source type), such that adding a new backend (S3) requires no change to the render or info flows.

#### Scenario: Backend-agnostic render flow
- **WHEN** the render endpoint is exercised with a local source
- **THEN** it uses only the storage seam (verified by an alternate/stub backend in tests), never local-filesystem calls inline
