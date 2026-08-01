## ADDED Requirements

### Requirement: HTTPS storage backend
The system SHALL implement the storage seam for HTTPS sources: metadata via an HTTP HEAD request, tolerating an origin that reports no size, and an ffmpeg input that is the canonical URL itself.

#### Scenario: Size reported
- **WHEN** the origin answers HEAD with a `Content-Length`
- **THEN** that size is returned for the caller's `AP_MAX_SRC_BYTES` check

#### Scenario: Size withheld
- **WHEN** the origin answers HEAD without a `Content-Length`
- **THEN** the source is reported as existing with an unknown size rather than rejected

#### Scenario: Unreachable source
- **WHEN** HEAD fails or answers 4xx/5xx
- **THEN** the source is reported not found

#### Scenario: Render input is the URL
- **WHEN** an authorized HTTPS source is rendered
- **THEN** ffmpeg receives the canonical URL as its input and performs its own fetching
