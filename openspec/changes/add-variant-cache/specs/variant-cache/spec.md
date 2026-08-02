## ADDED Requirements

### Requirement: Variant storage is a pluggable backend
The system SHALL address the variant store through a storage behaviour selected by the scheme of `AP_VARIANT_STORE`, supporting at minimum a local filesystem backend (`file://`) and an object-storage backend (`s3://`). Cache behaviour SHALL NOT depend on where source audio comes from.

#### Scenario: Local store with local sources
- **WHEN** `AP_VARIANT_STORE=file:///var/cache/audio_proxy` and sources resolve through `local://`
- **THEN** renders are cached and served from the cache with no object storage configured

#### Scenario: Unset store disables the cache
- **WHEN** `AP_VARIANT_STORE` is unset
- **THEN** every request renders (200 chunked) and nothing is written back

#### Scenario: Unusable store value fails at boot
- **WHEN** `AP_VARIANT_STORE` names an unknown scheme, or a `file://` path that does not exist or is not writable
- **THEN** the container exits nonzero with an error naming the variable

### Requirement: Completed renders are written back
The system SHALL, when `AP_VARIANT_STORE` is set, write each successfully completed render's bytes to the store under its cache key, and SHALL NOT leave partial output readable from failed or cancelled renders.

#### Scenario: Write-back on success
- **WHEN** a MISS render completes successfully
- **THEN** the stored variant's bytes are identical to the streamed response

#### Scenario: No partial persistence
- **WHEN** a render fails or is cancelled mid-stream
- **THEN** no variant is readable for that key (S3 multipart aborted; local temp file discarded, never renamed into place)

#### Scenario: Write failure is invisible to clients
- **WHEN** the write-back errors mid-render
- **THEN** client streaming completes normally and the failure is logged and instrumented

### Requirement: Cache hits are served without rendering
The system SHALL serve requests whose cache key exists in the store without starting a render, marking the response `X-Audio-Proxy: HIT`.

#### Scenario: Second request hits
- **WHEN** a variant was fully written back and the same URL is requested again
- **THEN** the response carries `X-Audio-Proxy: HIT` and no subprocess starts

#### Scenario: Redirect mode
- **WHEN** the store supports presigning and `AP_SERVE_MODE=redirect`
- **THEN** the response is `302` to a short-lived presigned URL

### Requirement: Serve mode must be supported by the store
The system SHALL treat redirect serving as a capability of the configured backend, and SHALL refuse at boot to run a serve mode the store cannot satisfy.

#### Scenario: Redirect against a local store is refused
- **WHEN** `AP_SERVE_MODE=redirect` and `AP_VARIANT_STORE` is a `file://` URL
- **THEN** the container exits nonzero with an error naming both variables, rather than failing per-request

### Requirement: Proxied serve mode
The system SHALL, when serving in proxy mode, stream the variant from the store with `Accept-Ranges`, honoring Range requests with 206 responses.

#### Scenario: Range request proxied
- **WHEN** a HIT is requested with `Range: bytes=100-199` in proxy mode
- **THEN** the response is 206 with exactly those 100 bytes and a correct `Content-Range`

#### Scenario: Range against a local store
- **WHEN** the store is `file://` and a Range request hits a cached variant
- **THEN** the requested byte range is served from the file without reading the whole object

### Requirement: Tee does not throttle rendering
The system SHALL render at full speed regardless of client consumption; the write-back subscriber consumes the render stream independently of client subscribers.

#### Scenario: Slow client
- **WHEN** a client consumes slowly while a render completes
- **THEN** the variant is complete in the store before the client finishes downloading
