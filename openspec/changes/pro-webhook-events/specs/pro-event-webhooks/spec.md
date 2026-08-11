## ADDED Requirements

### Requirement: Lifecycle events over Standard Webhooks
The system SHALL POST lifecycle events (`variant.rendered`, `variant.render_failed`, `variant.served`, `info.probed`) to each configured receiver as Standard-Webhooks envelopes — `webhook-id`, `webhook-timestamp`, `webhook-signature` (HMAC-SHA256 under a per-receiver secret distinct from the URL-signing key), versioned `type` — with payloads carrying the variant's full identity (source, options string, cache key) so the consuming app can correlate without passthrough metadata.

#### Scenario: Render completion notifies the receiver
- **WHEN** a MISS render completes and a receiver is configured for `variant.rendered`
- **THEN** the receiver gets a signed envelope whose payload names the source, options string, cache key, render duration, and output bytes

#### Scenario: Signature verifies with the reference algorithm
- **WHEN** a receiver verifies the envelope with a Standard Webhooks library
- **THEN** verification succeeds, and fails for a tampered payload or wrong secret

#### Scenario: Event-type filter
- **WHEN** a receiver is configured for only `variant.render_failed`
- **THEN** it receives failures and nothing else

### Requirement: Delivery never taxes the render path
Event delivery SHALL be at-least-once with exponential backoff up to a retry cap, buffered in a bounded in-memory queue that drops oldest under pressure while counting drops in a metric, and SHALL never block, slow, or fail a render or a response — including with an unreachable, stalled, or black-holed receiver.

#### Scenario: Stalled receiver costs renders nothing
- **WHEN** the receiver accepts connections but never responds
- **THEN** render latency is unchanged and the queue drops oldest past its bound, counting them

#### Scenario: Transient receiver failure retried
- **WHEN** a receiver answers 500 twice and then 200
- **THEN** the event arrives exactly once at the third attempt, with backoff between attempts

#### Scenario: Loss is bounded and honest
- **WHEN** the proxy stops with events queued
- **THEN** those events are gone — the contract states delivery is at-least-once for a live proxy, not durable across restarts
