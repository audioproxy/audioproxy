## ADDED Requirements

### Requirement: Cache hits are served without rendering
The system SHALL serve requests whose cache key exists in the store without starting a render, marking the response `X-Audio-Proxy: HIT`.

#### Scenario: Second request hits
- **WHEN** a variant was fully written back and the same URL is requested again
- **THEN** the response carries `X-Audio-Proxy: HIT` and no subprocess starts

#### Scenario: Redirect mode
- **WHEN** the store supports presigning and `AP_SERVE_MODE=redirect`
- **THEN** the response is `302` to a short-lived presigned URL

#### Scenario: The redirect itself is never cached
- **WHEN** a HIT is served as a `302`
- **THEN** the redirect response carries `Cache-Control: no-store` — a cached 302 would hand out presigned URLs that outlive their expiry

### Requirement: Proxied serve mode
The system SHALL, when serving in proxy mode, stream the variant from the store with `Accept-Ranges`, honoring Range requests with 206 responses. A cached variant has a known size, so a proxied HIT SHALL send `Content-Length` rather than chunked framing — declaring the length is what makes progress reporting, resumption and seeking possible.

#### Scenario: Plain GET on a hit
- **WHEN** a cached variant is requested in proxy mode with no `Range` header
- **THEN** the response is `200` with `Content-Length` and `Accept-Ranges: bytes`, relayed as it is read from the store

#### Scenario: Playback begins before the transfer completes
- **WHEN** a client reads a proxied HIT
- **THEN** first bytes arrive without waiting for the whole variant, and the proxy does not buffer the complete object in memory

#### Scenario: Range request proxied
- **WHEN** a HIT is requested with `Range: bytes=100-199` in proxy mode
- **THEN** the response is 206 with exactly those 100 bytes and a correct `Content-Range`

### Requirement: The client contract does not vary by backend
The observable contract SHALL be a property of the cache state, not of the configured store: same content type, caching semantics, validator and range capability for a given cache state, whichever backend and serve mode are configured. Backends differ in where bytes come from, never in what a client must implement.

#### Scenario: Same variant, different backend
- **WHEN** the same signed URL is requested against a `file://` deployment and an `s3://` one
- **THEN** the delivered bytes, `Content-Type`, `ETag` and `Cache-Control` are identical, and both are range-capable on a HIT

#### Scenario: Redirected hits carry the same metadata
- **WHEN** a HIT is served as a `302` and the client follows it
- **THEN** the store's response carries the same `Content-Type` and `Cache-Control` a proxied HIT would have sent

### Requirement: Cache state changes the framing of a response
The same URL SHALL be a chunked `200` without `Accept-Ranges` on a MISS, and a length-declared, range-capable `200` on a HIT; both begin delivering before the variant is complete or fully read. Clients SHALL NOT assume one framing for a given URL.

#### Scenario: A miss cannot be seeked, a hit can
- **WHEN** a variant is requested before it is cached and again afterwards
- **THEN** the first response is chunked with no `Accept-Ranges`, and the second answers a Range request with 206

#### Scenario: Redirected hits are ranged by the store
- **WHEN** the serve mode is `redirect` and the client follows the `302`
- **THEN** Range support and `Content-Length` come from the store or CDN serving that URL, not from the proxy
