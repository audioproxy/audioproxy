## ADDED Requirements

### Requirement: The retained backlog has its own configured ceiling
The system SHALL bound the bytes one render may retain by `AP_MAX_VARIANT_BYTES`, separately from the source ceiling `AP_MAX_SRC_BYTES`, so that a deployment can accept large sources while producing small outputs without licensing every render to retain a source-sized backlog.

`AP_MAX_VARIANT_BYTES` SHALL default to the effective value of `AP_MAX_SRC_BYTES`, so that a deployment configuring neither, or only the source ceiling, behaves exactly as it did before the two were separated.

#### Scenario: Large source, small output
- **WHEN** `AP_MAX_SRC_BYTES` admits a 3 GB source and `AP_MAX_VARIANT_BYTES` is 256 MB
- **THEN** a preview render of that source succeeds, and a full-length lossless render of it is killed at the retention bound

#### Scenario: The default preserves existing behaviour
- **WHEN** `AP_MAX_VARIANT_BYTES` is unset and `AP_MAX_SRC_BYTES` is set to a non-default value
- **THEN** retention is bounded at that same value, not at the shipped default

#### Scenario: The source ceiling no longer bounds retention
- **WHEN** `AP_MAX_VARIANT_BYTES` is set below `AP_MAX_SRC_BYTES`
- **THEN** a render whose output crosses the lower figure is killed even though it is under the source ceiling

### Requirement: A retention breach fails the request in flight
The system SHALL kill a render whose cumulative output crosses the retention bound and fail that request, rather than truncating silently or continuing to accumulate. The failure SHALL name the bound and the variable that set it.

Because the breach is detectable only after the response has committed to `200` and begun streaming, the outcome SHALL be a failed in-flight request rather than a `413`; the source ceiling remains the only one enforced before a render starts.

#### Scenario: Output crosses the bound mid-render
- **WHEN** a render's cumulative output exceeds `AP_MAX_VARIANT_BYTES`
- **THEN** the ffmpeg process is killed, the request fails, and the error names the byte figure and `AP_MAX_VARIANT_BYTES`

#### Scenario: Subscribers are told
- **WHEN** a render fails at the retention bound with several subscribers attached
- **THEN** every subscriber is failed, and the cache key is released so a subsequent request starts a fresh render rather than joining a dead one

#### Scenario: The bound is not a status code
- **WHEN** a request's response has already committed to `200` and the render then breaches the bound
- **THEN** the response is a failed stream rather than a `413`, which is reserved for oversized *sources* refused before rendering
