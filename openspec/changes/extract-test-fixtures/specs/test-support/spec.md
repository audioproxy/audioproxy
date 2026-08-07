## ADDED Requirements

### Requirement: Fixture paths are unique per run
A generated test fixture SHALL live under a path unique to the run that generated it, and SHALL be removed when that run ends.

#### Scenario: Two worktrees run the ffmpeg suite at once
- **WHEN** two `mix test --only ffmpeg` runs execute concurrently from separate worktrees
- **THEN** neither can read, truncate or delete a fixture belonging to the other, because they share no path

#### Scenario: A run leaves a directory behind
- **WHEN** a run crashes before its cleanup executes
- **THEN** the directory it left is named after the suite that created it

#### Scenario: A fixed path is proposed
- **WHEN** a test needs a generated file
- **THEN** it takes a path from the shared fixture helper, and never names a fixed path under the system temporary directory

### Requirement: Test outputs are separate from fixture inputs
A test that writes a file in order to inspect it SHALL write it outside the fixture root.

#### Scenario: A render is written out to be probed
- **WHEN** a test writes rendered bytes to disk so a prober can read them back
- **THEN** the file lands in that test's own temporary directory, not beside the module's shared inputs

### Requirement: Fixture generation has one home
The ffmpeg invocation that generates audio fixtures SHALL exist in one place.

#### Scenario: The generation arguments change
- **WHEN** the fixture-generation invocation needs a new flag
- **THEN** one helper changes and every generated fixture follows

#### Scenario: A fixture's character stays at the call site
- **WHEN** a fixture's duration, amplitude, rate or codec is what a test is about
- **THEN** that value is named where the fixture is requested, not defaulted inside the helper
