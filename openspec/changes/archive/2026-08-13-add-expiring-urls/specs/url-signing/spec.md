## ADDED Requirements

### Requirement: Expiry verification
The system SHALL answer 410 Gone for a request whose `exp` lies in the past, verified after signature verification and before source resolution or any render work, with a new `expired` error-table row and no clock-skew leeway.

#### Scenario: Expired URL answers 410
- **WHEN** a correctly signed request arrives after its `exp`
- **THEN** the response is 410 with the `expired` error envelope, and no source access or subprocess occurs

#### Scenario: Live URL unaffected
- **WHEN** a correctly signed request arrives before its `exp`
- **THEN** it proceeds exactly as a URL without `exp` would, hitting the same cache key

#### Scenario: The 410 is cacheable
- **WHEN** an edge caches a 410 for an expired URL
- **THEN** serving it stale-free forever is correct — the URL can never become valid — and the response's explicit `Cache-Control` permits it
