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

A cached variant has a known size, so a proxied HIT SHALL send `Content-Length` rather than the chunked framing a MISS uses. This is not a buffering decision: bytes are relayed as they are read either way, and declaring the length is what makes progress reporting, resumption and seeking possible.

#### Scenario: Plain GET on a hit
- **WHEN** a cached variant is requested in proxy mode with no `Range` header
- **THEN** the response is `200` with `Content-Length` and `Accept-Ranges: bytes`, and the body is relayed as it is read from the store

#### Scenario: Playback can begin before the transfer completes
- **WHEN** a client reads a proxied HIT
- **THEN** the first bytes arrive without waiting for the whole variant to be read out of the store, and the proxy SHALL NOT buffer the complete object in memory before responding

#### Scenario: Range request proxied
- **WHEN** a HIT is requested with `Range: bytes=100-199` in proxy mode
- **THEN** the response is 206 with exactly those 100 bytes and a correct `Content-Range`

#### Scenario: Range against a local store
- **WHEN** the store is `file://` and a Range request hits a cached variant
- **THEN** the requested byte range is served from the file without reading the whole object

### Requirement: The client contract does not vary by backend
The observable contract SHALL be a property of the cache state, not of the configured store. A client that follows redirects SHALL obtain the same content type, the same caching semantics, the same validator and the same range capability for a given cache state, whichever backend is configured and whichever serve mode is in use. Backends differ in where bytes come from, never in what a client must implement.

This is what keeps `AP_VARIANT_STORE` an operator decision. A client written against a `file://` deployment has to work unmodified against an `s3://` one, because the URL is the API and the storage choice is not part of it.

#### Scenario: Same variant, different backend
- **WHEN** the same signed URL is requested against a deployment using a `file://` store and against one using `s3://`
- **THEN** the delivered bytes, `Content-Type`, `ETag` and `Cache-Control` are identical, and both are range-capable on a HIT

#### Scenario: Redirected hits carry the same metadata
- **WHEN** a HIT is served as a `302` and the client follows it
- **THEN** the response from the store carries the same `Content-Type` and `Cache-Control` a proxied HIT would have sent

### Requirement: Write-back preserves response metadata
The system SHALL store each variant with the metadata needed to serve it correctly without the proxy in the path: at minimum its `Content-Type` and the immutable `Cache-Control` the render endpoint would have sent.

A store that keeps only bytes cannot satisfy the contract above. A redirected fetch would return the backend's default type, and a player asked to decode `application/octet-stream` may simply refuse.

#### Scenario: Content type survives the round trip
- **WHEN** an `f:opus` variant is written back and later fetched directly from the store
- **THEN** it is served as `audio/ogg`, not as the store's default type

#### Scenario: Backends without metadata support
- **WHEN** a backend cannot attach metadata to a stored object
- **THEN** it SHALL NOT advertise the redirect capability, so its hits are proxied and the proxy supplies the headers

### Requirement: Cache state changes the framing of a response
The same URL SHALL be delivered as a chunked `200` without `Accept-Ranges` on a MISS, and as a length-declared, range-capable `200` on a HIT. Both SHALL begin delivering bytes before the variant is complete or fully read, so a player can start on either. Clients SHALL NOT assume one framing for a given URL.

#### Scenario: A miss cannot be seeked, a hit can
- **WHEN** a variant is requested before it is cached and again afterwards
- **THEN** the first response is chunked and advertises no `Accept-Ranges`, and the second accepts a `Range` request and answers 206

#### Scenario: Redirected hits are ranged by the store
- **WHEN** the serve mode is `redirect` and the client follows the `302`
- **THEN** Range support and `Content-Length` come from the store or CDN serving that URL, not from the proxy

### Requirement: Tee does not throttle rendering
The system SHALL render at full speed regardless of client consumption; the write-back subscriber consumes the render stream independently of client subscribers.

#### Scenario: Slow client
- **WHEN** a client consumes slowly while a render completes
- **THEN** the variant is complete in the store before the client finishes downloading
