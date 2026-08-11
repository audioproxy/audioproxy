## ADDED Requirements

### Requirement: Expiry caps every lifetime the response hands out
For a request carrying `exp`, the system SHALL clamp the response's `Cache-Control` `max-age` to at most `exp − now` on successful responses, and SHALL clamp the presigned TTL of a HIT redirect's Location to at most `exp − now` — so that no cache entry and no storage-level credential issued for an expiring URL outlives the URL itself.

#### Scenario: Cached body dies with the URL
- **WHEN** a 200 is served for a URL expiring in 60 seconds under a configured `max-age` of 3600
- **THEN** the response's `max-age` is at most 60

#### Scenario: Redirect credential dies with the URL
- **WHEN** a HIT redirect is served for a URL expiring in 30 seconds under `AP_PRESIGN_TTL` of 3600
- **THEN** the presigned URL in Location expires within 30 seconds

#### Scenario: No exp, no clamp
- **WHEN** a request carries no `exp`
- **THEN** cache and presign lifetimes are exactly what configuration says today
