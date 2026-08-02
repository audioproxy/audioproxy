## ADDED Requirements

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

### Requirement: HEAD is supported on signed endpoints
The system SHALL answer HEAD requests on the render endpoint with the same status and headers a GET would produce through the full check chain (signature, options, source authorize + stat), an empty body, and no render subprocess.

#### Scenario: HEAD on a valid variant URL
- **WHEN** a valid signed render URL receives a HEAD request
- **THEN** the response is 200 with `Content-Type`, `Cache-Control`, and `ETag`, an empty body, and no ffmpeg process was spawned

#### Scenario: HEAD reports errors like GET
- **WHEN** a HEAD request has a bad signature or names a missing source
- **THEN** it answers 401 or 404 with the same headers as GET (bodiless)

### Requirement: Range on an uncached variant is ignored
The system SHALL answer a render (MISS) request carrying a `Range` header with the full `200` chunked stream, ignoring the header; 206 semantics belong to cached variants only.

#### Scenario: Seek into a cold URL
- **WHEN** an uncached render request carries `Range: bytes=1000-`
- **THEN** the response is the normal full 200 chunked stream with no `Accept-Ranges` and no 206
