## ADDED Requirements

### Requirement: Shared script plumbing has one home
The identical docker and shell helpers used by more than one `bin/` script SHALL live in a single support file that those scripts load, together with the comments explaining why each is shaped as it is.

#### Scenario: A correction is made once
- **WHEN** a docker-invocation hazard is corrected in the shared helper
- **THEN** every script that uses it carries the correction, with no stale duplicate left behind

#### Scenario: Divergent helpers stay divergent
- **WHEN** helpers differ between scripts because their callers need different behaviour
- **THEN** they remain in their own scripts rather than being unified

### Requirement: The cgroup sampler is implemented once
The `anon` sampling probe used to measure peak private memory SHALL exist in one place, taking its sampling interval as an explicit parameter.

#### Scenario: Both callers sample identically
- **WHEN** `bin/measure-ffmpeg-rss` and `bin/check-capacity` sample a container's anonymous memory
- **THEN** both use the same implementation, and any interval difference is visible at the call site

### Requirement: The scripts behave identically after extraction
Extraction SHALL NOT change the observable behaviour of any `bin/` script.

#### Scenario: Verified by running, not by reading
- **WHEN** the three scripts are run before and after the change
- **THEN** their outcomes match, including `bin/smoke-image`, which gates image publication
