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
naming the variables, rather than failing per-request. Serving from the store —
HIT paths, Range, response framing — is specified separately; this capability
covers the store machinery and write-back.

## Requirements

### Requirement: Variant storage is a pluggable backend
The system SHALL address the variant store through a storage behaviour selected by the scheme of `AP_VARIANT_STORE`, supporting at minimum a local filesystem backend (`file://`) and an object-storage backend (`s3://`, landing with `add-s3-client`). Cache behaviour SHALL NOT depend on where source audio comes from.

#### Scenario: Local store with local sources
- **WHEN** `AP_VARIANT_STORE=file:///var/cache/audio_proxy` and sources resolve through `local://`
- **THEN** renders are cached with no object storage configured

#### Scenario: Unset store disables the cache
- **WHEN** `AP_VARIANT_STORE` is unset
- **THEN** every request renders (200 chunked) and nothing is written back

#### Scenario: Unusable store value fails at boot
- **WHEN** `AP_VARIANT_STORE` names an unknown scheme, or a `file://` path that does not exist or is not writable
- **THEN** the container exits nonzero with an error naming the variable

### Requirement: Serve mode must be supported by the store
The system SHALL treat redirect serving as a capability of the configured backend, and SHALL refuse at boot to run a serve mode the store cannot satisfy.

#### Scenario: Redirect against a local store is refused
- **WHEN** `AP_SERVE_MODE=redirect` and `AP_VARIANT_STORE` is a `file://` URL
- **THEN** the container exits nonzero with an error naming both variables, rather than failing per-request

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
