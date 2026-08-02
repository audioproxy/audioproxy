## ADDED Requirements

### Requirement: Batch warm endpoint
The system SHALL serve `GET /{sig}/warm/enc:{payload}` — payload a base64url JSON list of `{options}/{source}` entries, authorized by the outer signature alone — starting a render for each entry not already cached and responding without waiting for any render to complete.

#### Scenario: Cold entries start rendering
- **WHEN** a signed warm request lists three uncached variants
- **THEN** the response returns promptly with each entry `started`, and the variants subsequently appear in the store without further requests

#### Scenario: Warm entries are recognized
- **WHEN** an entry's cache key already exists in the store
- **THEN** it is reported `hit` and no render starts

#### Scenario: Fire and forget
- **WHEN** the warm client disconnects immediately after the response
- **THEN** started renders complete into the store regardless

### Requirement: Per-entry validation, bounded batches
The system SHALL validate each entry independently — invalid options or unauthorized sources are reported per entry with the same error classes as a direct request, never failing the batch — and SHALL reject payloads exceeding the entry limit (default 100) or that are undecodable, with 422.

#### Scenario: Mixed batch
- **WHEN** a batch contains one valid entry, one with unknown options, one with a disallowed source
- **THEN** the response reports `started`, `invalid` (options error), and `invalid` (authorization) respectively, and the valid entry renders

#### Scenario: Oversized batch
- **WHEN** the payload lists more than the entry limit
- **THEN** the response is 422 and nothing starts

### Requirement: Warming shares the render governance
Warm-started renders SHALL pass through the same coalescing and concurrency limiting as interactive renders: duplicates coalesce (including against in-flight interactive renders), the semaphore paces the batch, and queue overflow is reported per entry rather than dropping work silently.

#### Scenario: Duplicate of an in-flight render
- **WHEN** a warm entry names a variant already rendering for an interactive client
- **THEN** no second subprocess starts

#### Scenario: Saturation is visible
- **WHEN** the render queue cannot admit further entries
- **THEN** affected entries are reported as rejected (queue-full) in the response, and the client may retry them

### Requirement: Warming requires a variant store
The system SHALL answer warm requests with 422 when `AP_VARIANT_STORE` is unset — a warmed render with nowhere to persist is a wasted render, refused loudly rather than silently discarded.

#### Scenario: No store configured
- **WHEN** a warm request arrives with the cache disabled
- **THEN** the response is 422 naming the missing configuration
