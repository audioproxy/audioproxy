# edge-caching Specification

## Purpose
Stated cache policy at the edge of the proxy, replacing framework defaults with
a decision this project made. Every response class declares its own
cacheability: media bodies are immutable and transform-proof, verdicts about
source bytes are negative-cached briefly so a re-upload is picked up promptly,
deterministic client errors cache a little longer, and transient failures are
never stored.

This is safe because the API is already CDN-shaped. A response body is a pure
function of the URL, carries nothing per-user, and has no cookie or auth header
to vary on — which is also what makes the cheap paths possible. The `ETag` is
derivable from the URL alone, so a conditional request can be answered with
`304` after signature verification and before any storage access or render, and
a HEAD can report exactly what a GET would without spawning an encoder.

Range is scoped deliberately: on an uncached render the header is ignored and
the full chunked `200` is streamed. 206 semantics belong to cached variants,
served by the store, not to a stream being produced as it is sent.

## Requirements

### Requirement: Every response declares its cacheability
The system SHALL set an explicit `Cache-Control` on every response: the immutable media policy on 200s, `max-age=10` on 404, 413, and 415 (verdicts about the current source bytes, which a re-upload changes), `max-age=60` on 401 and 422 (deterministic per URL), and `no-store` on 429 and 5xx-class responses including 504 — so no CDN negative-caching default ever decides retention.

#### Scenario: Missing source is briefly negative-cached
- **WHEN** a request 404s
- **THEN** the response carries `Cache-Control: max-age=10`, so a source uploaded moments later is served promptly

#### Scenario: Source-verdict errors follow the 404 row
- **WHEN** a request answers 413 or 415
- **THEN** the response carries `Cache-Control: max-age=10`, because the verdict is about source bytes a re-upload changes

#### Scenario: Deterministic client errors cache briefly
- **WHEN** a request answers 401 or 422
- **THEN** the response carries `Cache-Control: max-age=60`

#### Scenario: Transient failures are never cached
- **WHEN** a request answers 429 or 504
- **THEN** the response carries `Cache-Control: no-store`

### Requirement: Media responses are transform-proof
The system SHALL include `no-transform` in the `Cache-Control` of every media response (audio bodies and binary peaks), preventing intermediary recompression or modification.

#### Scenario: Directive present
- **WHEN** any 200 media response is inspected
- **THEN** its `Cache-Control` contains `no-transform` alongside the immutable policy

### Requirement: Conditional requests are answered from the URL
The system SHALL answer a render request whose `If-None-Match` matches the URL-derived `ETag` with `304 Not Modified` — after signature verification, before any storage access or render — carrying the `ETag` and `Cache-Control` headers and no body.

#### Scenario: Revalidation costs no render
- **WHEN** a signed render request carries `If-None-Match` equal to the variant's ETag
- **THEN** the response is 304 with no render spawned and no store accessed

#### Scenario: Stale validator proceeds normally
- **WHEN** `If-None-Match` does not match
- **THEN** the request proceeds exactly as without the header

#### Scenario: Signature still gates
- **WHEN** an unsigned request carries a matching `If-None-Match`
- **THEN** the response is 401, not 304

### Requirement: Range on an uncached variant is ignored
The system SHALL answer a render (MISS) request carrying a `Range` header with the full `200` chunked stream, ignoring the header; 206 semantics belong to cached variants only.

#### Scenario: Seek into a cold URL
- **WHEN** an uncached render request carries `Range: bytes=1000-`
- **THEN** the response is the normal full 200 chunked stream with no `Accept-Ranges` and no 206

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
