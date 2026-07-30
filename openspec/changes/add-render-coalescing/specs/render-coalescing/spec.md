## ADDED Requirements

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
