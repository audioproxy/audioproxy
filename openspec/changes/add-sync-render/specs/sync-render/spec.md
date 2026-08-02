## ADDED Requirements

### Requirement: A client may request a complete, seekable variant
The system SHALL provide a delivery mode, requested as `/sync/{signature}/{options}/{source}`, in which an uncached variant is rendered to completion before the response body begins, answered with `Content-Length` and `Accept-Ranges`, or `206` when a byte range was requested. The prefix SHALL be covered by the signature, and SHALL NOT form part of the variant's cache key: byte-identical variants have one identity however they were delivered.

#### Scenario: A sync URL yields a complete response
- **WHEN** an uncached variant is requested as `/sync/{signature}/{options}/{source}`
- **THEN** the render completes first and the response carries `Content-Length` and `Accept-Ranges`, or `206` with a correct `Content-Range` if a range was requested

#### Scenario: Delivery mode does not fork the cache key
- **WHEN** the same variant is fetched once by its plain URL and once by its `/sync/` URL
- **THEN** both resolve to the same cache key and the store holds one object

#### Scenario: Streaming stays the default
- **WHEN** an uncached variant is requested by its plain URL
- **THEN** the response is the chunked `200` of API doc §5, unchanged, whatever `Range` header the client sent

#### Scenario: The prefix is covered by the signature
- **WHEN** a signature issued for a plain URL is replayed with `/sync/` prepended
- **THEN** verification fails, so holding a streaming URL cannot be escalated into a held render slot

### Requirement: Materialised renders populate the store
The system SHALL write a materialised variant back to the configured store on completion, so that the cost of waiting is paid once.

#### Scenario: The next request is an ordinary hit
- **WHEN** a variant has been materialised and is requested again
- **THEN** it is served as a cache HIT with no render

### Requirement: Materialising without a store is bounded
The system SHALL NOT hold a complete variant in memory in order to serve it. With no variant store configured, materialising SHALL spool to disk and remove the spool once the response completes.

#### Scenario: Spooled to disk, not memory
- **WHEN** a variant is materialised with no store configured
- **THEN** the bytes are written to the configured spool directory and the process's memory does not grow with the variant's size

#### Scenario: Spool removed after the response
- **WHEN** a materialised response completes, fails or is cancelled
- **THEN** no spool file for that render remains

#### Scenario: Nowhere to put it degrades rather than fails
- **WHEN** materialisation is requested with neither a variant store nor a usable spool directory
- **THEN** the request is answered as an ordinary chunked MISS rather than an error

### Requirement: A materialising request is charged like any other render
A materialising request SHALL acquire a render slot for the duration of its render and SHALL be subject to `AP_RENDER_TIMEOUT`, so that holding a connection open cannot bypass the limits that protect the render pool.

#### Scenario: Queue pressure applies
- **WHEN** materialising requests arrive faster than the render pool can serve them
- **THEN** they queue and overflow to `429` on the same terms as streaming renders

#### Scenario: Timeout applies
- **WHEN** a materialising render exceeds `AP_RENDER_TIMEOUT`
- **THEN** the subprocess is killed and the request is answered `504`
