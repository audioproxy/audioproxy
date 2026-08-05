## ADDED Requirements

### Requirement: S3 sources resolve through the storage seam
The system SHALL implement `AudioProxy.Source.Type`'s `stat/1` and `ffmpeg_input/1` for `s3://` sources — `stat/1` reporting size and ETag from an object HEAD, `ffmpeg_input/1` returning a presigned GET URL valid for `AP_PRESIGN_TTL` — so that the render and info flows gain S3 sources without changes of their own. `{:error, :no_backend}` SHALL no longer be reachable for this source type.

#### Scenario: Render from an S3 source
- **WHEN** a signed render URL names an `s3://` source in an allowlisted bucket
- **THEN** the variant is rendered from a presigned GET URL handed to ffmpeg as a single argv element, and no source bytes pass through the BEAM

#### Scenario: Info from an S3 source
- **WHEN** info is requested for an `s3://` source
- **THEN** the response is the §4 contract, with `size` from the HEAD and an `ETag` derived from the object's own ETag

#### Scenario: Oversized S3 source
- **WHEN** a render names an `s3://` object whose HEAD reports a size above `AP_MAX_SRC_BYTES`
- **THEN** the response is 413 and no subprocess is spawned, while the same object is still described by `/info`

### Requirement: Storage failures classify by cause, not by convenience
The system SHALL map every `AudioProxy.S3` error shape explicitly, with no catch-all: a missing object and a denied credential SHALL both answer the blind 404, an unconfigured client SHALL answer 500, and a transport failure or an upstream 5xx SHALL answer the upstream-failure row. Collapsing an outage into the 404 is forbidden — it reports a deletion that did not happen, and is then edge-cached.

#### Scenario: Denied credential is indistinguishable from a missing object
- **WHEN** the bucket policy denies HEAD for an object that exists
- **THEN** the response is byte-identical to the 404 for an object that does not, and the log names `access_denied`

#### Scenario: Store outage
- **WHEN** S3 answers 5xx or the request fails at the transport
- **THEN** the response is the upstream-failure row, not a 404

#### Scenario: Unconfigured client
- **WHEN** an `s3://` source is requested with no credentials configured
- **THEN** the response is 500, since no client action can resolve it
