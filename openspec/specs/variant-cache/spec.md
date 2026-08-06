# variant-cache Specification

## Purpose
Persist completed renders so the next request for the same variant is served
from storage instead of re-encoding. The variant store is addressed through a
storage behaviour selected by the scheme of `AP_VARIANT_STORE` — a local
filesystem backend or an object-storage backend — and cache behaviour is
independent of where source audio comes from. Unset, the cache is off and every
request renders.

Write-back is a tee: a subscriber on the render's chunk stream that consumes at
full render speed, independent of any client, and lands each successful render
atomically with the response metadata (`Content-Type`, immutable
`Cache-Control`) a store-direct fetch needs to serve correctly. Failed or
cancelled renders leave nothing readable — variants are atomic-or-absent — and
a write-back failure is logged and instrumented but never visible to the
client's stream. With a store configured, the tee counts as a subscriber, so
the render completes into the store even if every client disconnects.

Serve modes are capabilities of the configured backend: a mode the store cannot
satisfy (redirect against a backend that cannot presign) is refused at boot,
naming the variables, rather than failing per-request.

Reading back out is the other half, and its requirements are below: a hit is
detected before coalescing and before the source is stat'd, then either
proxied with `Content-Length` and Range support or answered with a short-lived
redirect. What a client observes is a property of the cache state — the same
URL is chunked and unseekable while it renders, length-declared and
range-capable once it is stored — never of the configured backend or serve
mode.
## Requirements
### Requirement: Variant storage is a pluggable backend
The system SHALL address the variant store through a storage behaviour selected by the scheme of `AP_VARIANT_STORE`, supporting a local filesystem backend (`file://`) and an object-storage backend (`s3://`). Cache behaviour SHALL NOT depend on where source audio comes from. Both schemes SHALL be validated at boot by the operation the store actually needs — a write and its removal, not an inspection of permissions — so that a deployment pointed at a store it cannot write fails to start rather than rendering every variant twice and discarding the write-back.

#### Scenario: Local store with local sources
- **WHEN** `AP_VARIANT_STORE=file:///var/cache/audio_proxy` and sources resolve through `local://`
- **THEN** renders are cached with no object storage configured

#### Scenario: Object store
- **WHEN** `AP_VARIANT_STORE=s3://bucket` with credentials configured
- **THEN** renders are cached to that bucket and served back from it, and the cache survives a container restart

#### Scenario: Unset store disables the cache
- **WHEN** `AP_VARIANT_STORE` is unset
- **THEN** every request renders (200 chunked) and nothing is written back

#### Scenario: Unusable store value fails at boot
- **WHEN** `AP_VARIANT_STORE` names an unknown scheme, a `file://` path that does not exist or is not writable, or an `s3://` bucket that is unreachable, refuses a write, or refuses to remove what it just accepted
- **THEN** the container exits nonzero with an error naming the variable, and a refused write and a refused removal say which one happened — the second leaves an object behind and needs a different permission granted

#### Scenario: A store URL that says more than the scheme supports fails at boot
- **WHEN** an `s3://` value carries a key prefix, a port, embedded credentials, a query or a fragment
- **THEN** the container exits nonzero rather than ignoring the part it cannot honour, and an error naming credentials does not echo them

### Requirement: Serve mode must be supported by the store
The system SHALL treat redirect serving as a capability of the configured backend, and SHALL refuse at boot to run a serve mode the store cannot satisfy. The `s3://` backend SHALL declare the presign capability, which is what makes `AP_SERVE_MODE=redirect` — the documented default — reachable.

#### Scenario: Redirect against a local store is refused
- **WHEN** `AP_SERVE_MODE=redirect` and `AP_VARIANT_STORE` is a `file://` URL
- **THEN** the container exits nonzero with an error naming both variables, rather than failing per-request

#### Scenario: Redirect against an object store is served
- **WHEN** `AP_SERVE_MODE=redirect`, the store is `s3://`, and a variant is cached
- **THEN** the response is a `302` to a presigned URL valid for `AP_PRESIGN_TTL`, carrying `Cache-Control: no-store`

### Requirement: Completed renders are written back
The system SHALL, when `AP_VARIANT_STORE` is set, write each successfully completed render's bytes to the store under its cache key, and SHALL NOT leave partial output readable from failed or cancelled renders.

#### Scenario: Write-back on success
- **WHEN** a MISS render completes successfully
- **THEN** the stored variant's bytes are identical to the streamed response

#### Scenario: No partial persistence
- **WHEN** a render fails or is cancelled mid-stream
- **THEN** no variant is readable for that key (local temp file discarded, never renamed into place; S3 multipart aborted once that backend exists)

#### Scenario: Write failure is invisible to clients
- **WHEN** the write-back errors mid-render
- **THEN** client streaming completes normally and the failure is logged and instrumented

#### Scenario: Sole-client disconnect completes the render
- **WHEN** the only client disconnects mid-render with a store configured
- **THEN** the render completes into the store (with no store, it is cancelled as before)

### Requirement: Write-back preserves response metadata
The system SHALL store each variant with the metadata needed to serve it correctly without the proxy in the path: at minimum its `Content-Type` and the immutable `Cache-Control` the render endpoint would have sent. A backend that cannot attach metadata SHALL NOT advertise the redirect capability.

#### Scenario: Content type survives the round trip
- **WHEN** an `f:opus` variant is written back and later fetched directly from the store
- **THEN** it is served as `audio/ogg`, not as the store's default type

### Requirement: Tee does not throttle rendering
The system SHALL render at full speed regardless of client consumption; the write-back subscriber consumes the render stream independently of client subscribers.

#### Scenario: Slow client
- **WHEN** a client consumes slowly while a render completes
- **THEN** the variant is complete in the store before the client finishes downloading

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

### Requirement: Backends are proved equivalent by one suite
The system SHALL exercise every storage backend against a single shared set of assertions covering the seam's whole surface — round-tripping bytes and metadata, ranged reads, a miss on an absent key, and a failed write leaving the response unaffected — so that agreement between backends is enforced rather than intended. Backend-specific mechanisms SHALL be tested separately from that suite.

#### Scenario: Every backend answers the seam identically
- **WHEN** the shared suite runs against `file://` and `s3://`
- **THEN** both satisfy every assertion, and a backend that diverges fails the suite rather than surprising a deployment

#### Scenario: A failed write does not fail the request
- **WHEN** the write-back fails against either backend
- **THEN** the client still receives the complete rendered variant, and the failure is reported as telemetry

