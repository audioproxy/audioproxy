# dev-tooling Specification

## Purpose
The operational Ruby scripts under `bin/` — the image smoke suite, the capacity
check, the RSS measurement probe — and the rule that decides what they are
allowed to duplicate.

The scripts talk to docker, and the way they talk to it encodes failures someone
already paid for: stderr kept out of return values because docker writes
advisories there, a container id picked out by shape rather than by taking "the
output", a published port read back rather than chosen. That knowledge is worth
more than the lines it occupies, and three copies of it means a correction to one
leaves two stale.

So the boundary is drawn on kind, not on similarity. Plumbing that is identical
across callers — docker invocation, shell escape hatches, the cgroup sampler —
lives once. Presentation and per-script policy (`log`, `check`, health polling,
fixture generation) stay where they are, because unifying them means picking a
loser between callers that deliberately differ. A helper that is neither — the
MiB conversion, which is arithmetic the published model owns — lives once too,
but with the model rather than the plumbing.

Out of scope: the capacity model's constants, arithmetic and table parser, which
are domain rather than plumbing and live in their own support file — see
`capacity-model`. CI's use of these scripts belongs to `ci-pipeline`.

## Requirements
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
