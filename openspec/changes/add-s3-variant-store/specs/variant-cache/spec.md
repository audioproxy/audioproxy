## MODIFIED Requirements

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
- **WHEN** `AP_VARIANT_STORE` names an unknown scheme, a `file://` path that does not exist or is not writable, or an `s3://` bucket that is unreachable or refuses a write
- **THEN** the container exits nonzero with an error naming the variable

### Requirement: Serve mode must be supported by the store
The system SHALL treat redirect serving as a capability of the configured backend, and SHALL refuse at boot to run a serve mode the store cannot satisfy. The `s3://` backend SHALL declare the presign capability, which is what makes `AP_SERVE_MODE=redirect` — the documented default — reachable.

#### Scenario: Redirect against a local store is refused
- **WHEN** `AP_SERVE_MODE=redirect` and `AP_VARIANT_STORE` is a `file://` URL
- **THEN** the container exits nonzero with an error naming both variables, rather than failing per-request

#### Scenario: Redirect against an object store is served
- **WHEN** `AP_SERVE_MODE=redirect`, the store is `s3://`, and a variant is cached
- **THEN** the response is a `302` to a presigned URL valid for `AP_PRESIGN_TTL`, carrying `Cache-Control: no-store`

## ADDED Requirements

### Requirement: Backends are proved equivalent by one suite
The system SHALL exercise every storage backend against a single shared set of assertions covering the seam's whole surface — round-tripping bytes and metadata, ranged reads, a miss on an absent key, and a failed write leaving the response unaffected — so that agreement between backends is enforced rather than intended. Backend-specific mechanisms SHALL be tested separately from that suite.

#### Scenario: Every backend answers the seam identically
- **WHEN** the shared suite runs against `file://` and `s3://`
- **THEN** both satisfy every assertion, and a backend that diverges fails the suite rather than surprising a deployment

#### Scenario: A failed write does not fail the request
- **WHEN** the write-back fails against either backend
- **THEN** the client still receives the complete rendered variant, and the failure is reported as telemetry
