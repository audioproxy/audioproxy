# render-coalescing Specification

## Purpose
One render per in-flight cache key. Concurrent requests for the same
not-yet-cached variant attach to the render already running instead of each
starting an encoder, and a request that attaches mid-render is given every byte
produced so far before the live ones, so it receives the whole variant rather
than its tail.

The deduplication key is the cache key, which is the normalized options plus the
canonical source — the same identity the `ETag` carries. Two requests coalesce
exactly when they describe the same variant.

What makes the start race a non-event is that starting and joining are one
operation rather than a check followed by an act: the caller that wins
registration is the render's starter, and the caller that loses is handed the
running one. Nothing asks whether a render exists before deciding to begin.

Scope is a single node and the lifetime of the render. Nothing survives a
render's completion — persistence is the variant cache's capability, and
cross-node coalescing is not attempted. Bounding *how many* distinct renders may
run at once is likewise separate, and belongs to the concurrency semaphore; what
this capability bounds is duplication of one variant, not total load.

## Requirements

### Requirement: One render per in-flight cache key
The system SHALL run at most one render per cache key at any time; concurrent subscribers for the same key attach to the single running render, including under start races.

#### Scenario: Concurrent burst
- **WHEN** 20 processes subscribe to the same cache key simultaneously
- **THEN** exactly one subprocess render starts and all 20 receive the complete byte stream

#### Scenario: Distinct keys are independent
- **WHEN** two different cache keys are subscribed concurrently
- **THEN** two independent renders run

### Requirement: Late joiners receive the full stream
The system SHALL deliver to a subscriber that joins mid-render all previously produced bytes (in order) before live chunks, with no gap or overlap at the seam.

#### Scenario: Mid-render join
- **WHEN** a subscriber joins after N chunks have been broadcast
- **THEN** it receives those N chunks as backlog, then subsequent chunks, and its concatenation equals the first subscriber's

### Requirement: Coalescing status is reported
The system SHALL distinguish the render-starting subscriber (MISS) from attaching subscribers (COALESCED).

#### Scenario: Status assignment
- **WHEN** two requests coalesce on one key
- **THEN** the first reports MISS and the second COALESCED

### Requirement: Subscriber lifecycle does not corrupt the render
The system SHALL continue the render for remaining subscribers when one subscriber dies, and SHALL cancel the render and release its concurrency slot when the last subscriber disappears.

#### Scenario: One of many disconnects
- **WHEN** one of three subscribers dies mid-render
- **THEN** the other two receive the complete stream

#### Scenario: All subscribers gone
- **WHEN** every subscriber has died mid-render
- **THEN** the subprocess is terminated and the semaphore slot released

### Requirement: Failure propagates to all subscribers
The system SHALL deliver a render failure exactly once to every current subscriber and clear the key so a subsequent request may retry.

#### Scenario: Mid-render failure
- **WHEN** the pipeline reports an error after some chunks
- **THEN** all subscribers receive the error, and a new subscribe on the same key starts a fresh render

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
