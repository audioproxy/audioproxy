## ADDED Requirements

### Requirement: Completed renders are written back
The system SHALL, when `AP_VARIANT_BUCKET` is set, upload each successfully completed render's bytes to the variant bucket under its cache key, and SHALL NOT persist partial output from failed or cancelled renders.

#### Scenario: Write-back on success
- **WHEN** a MISS render completes successfully
- **THEN** the variant object exists with bytes identical to the streamed response

#### Scenario: No partial persistence
- **WHEN** a render fails or is cancelled mid-stream
- **THEN** no variant object exists for that key (multipart aborted)

#### Scenario: Upload failure is invisible to clients
- **WHEN** the variant-bucket upload errors mid-render
- **THEN** client streaming completes normally and the failure is logged/instrumented

### Requirement: Cache hits are served from the variant bucket
The system SHALL serve requests whose cache key exists in the variant bucket without rendering: by default `302` to a short-lived presigned GET URL with `X-Audio-Proxy: HIT`.

#### Scenario: Second request redirects
- **WHEN** a variant was fully written back and the same URL is requested again
- **THEN** the response is 302 with a presigned Location, `X-Audio-Proxy: HIT`, and no subprocess starts

#### Scenario: Cache disabled
- **WHEN** `AP_VARIANT_BUCKET` is unset
- **THEN** every request renders (200 chunked) and nothing is uploaded

### Requirement: Proxied serve mode
The system SHALL, when `AP_SERVE_MODE=proxy`, serve HITs through the proxy with `Accept-Ranges`, honoring Range requests with 206 responses passed through from the store.

#### Scenario: Range request proxied
- **WHEN** a HIT is requested with `Range: bytes=100-199` in proxy mode
- **THEN** the response is 206 with exactly those 100 bytes and correct `Content-Range`

### Requirement: Tee does not throttle rendering
The system SHALL render at full speed regardless of client consumption; the write-back subscriber consumes the render stream independently of client subscribers.

#### Scenario: Slow client
- **WHEN** a client consumes slowly while a render completes
- **THEN** the variant object is complete in the bucket even before the client finishes downloading
