## ADDED Requirements

### Requirement: Configurable request addressing
The system SHALL address S3 requests either path-style (`endpoint/bucket/key`) or virtual-hosted (`bucket.endpoint/key`), selected by configuration, and SHALL use the same style for signed requests and for presigned URLs.

The default SHALL be virtual-hosted when no custom endpoint is configured, and path-style when one is, so that AWS gets the style it requires and existing S3-compatible deployments keep the style they work with.

#### Scenario: Virtual-hosted addressing
- **WHEN** addressing is configured virtual-hosted
- **THEN** a request for an object is sent to `bucket.endpoint-host` with the key as the whole path

#### Scenario: Path-style addressing
- **WHEN** addressing is configured path-style
- **THEN** a request for an object is sent to the endpoint host with the bucket leading the path

#### Scenario: Presigned URLs use the configured style
- **WHEN** an object is presigned
- **THEN** the URL's host and path follow the same addressing style as a signed request would, because the host is covered by the signature and a URL addressed differently cannot be verified

#### Scenario: Default without a custom endpoint
- **WHEN** no custom endpoint is configured and addressing is not set
- **THEN** addressing is virtual-hosted, which is what AWS regions launched after 2019 require

#### Scenario: Default with a custom endpoint
- **WHEN** a custom endpoint is configured and addressing is not set
- **THEN** addressing is path-style, preserving the behaviour every currently documented S3-compatible provider is configured against

#### Scenario: An unusable value is refused at boot
- **WHEN** addressing is set to anything other than the two supported styles
- **THEN** startup fails naming the variable, rather than the value being ignored

### Requirement: Configurable TLS trust
The system SHALL verify the store's certificate chain against the system trust store by default, and against an operator-supplied certificate bundle when one is configured, so that a self-hosted store behind a private certificate authority can be reached over TLS.

The system SHALL NOT offer a way to disable certificate verification.

#### Scenario: Default trust
- **WHEN** no certificate bundle is configured
- **THEN** the system trust store is used

#### Scenario: Supplied bundle
- **WHEN** a certificate bundle is configured
- **THEN** it is used instead of the system trust store, and a store presenting a certificate signed by that authority is reached over `https://`

#### Scenario: An unreadable bundle is refused at boot
- **WHEN** the configured bundle does not name a readable file
- **THEN** startup fails naming the variable, rather than failing on the first request

## MODIFIED Requirements

### Requirement: Presigned GET URLs
The system SHALL generate SigV4 presigned GET URLs for S3 objects with a configurable expiry, valid against AWS S3 and S3-compatible endpoints (custom endpoint, region and addressing style).

#### Scenario: A presigned URL is accepted by the store
- **WHEN** an object is presigned and the URL fetched by a client that sends no credentials of its own
- **THEN** the store returns the object's bytes

#### Scenario: An unsigned URL is refused
- **WHEN** the same object is fetched without the signature
- **THEN** the store refuses it, so the signature is what granted access rather than a public bucket

#### Scenario: A tampered signature is refused
- **WHEN** a single character of `X-Amz-Signature` is altered
- **THEN** the store refuses the request

#### Scenario: Expiry honored
- **WHEN** a URL is presigned with a short expiry and fetched after it elapses
- **THEN** the store refuses it

#### Scenario: Key escaping
- **WHEN** presigning a key containing spaces, `+`, or non-ASCII characters
- **THEN** the URL fetches that object, and keys differing only in escaping (`a b` versus `a%20b`) address different objects

#### Scenario: Addressing matches the request path
- **WHEN** the configured addressing style is changed
- **THEN** the presigned URL's host and path change with it, so a presigned URL and a signed request never disagree about which host they address

### Requirement: Streaming upload of unknown length
The system SHALL upload a stream of chunks whose total length is not known in advance, choosing a single-request upload for a stream that fits within one part and a multipart upload otherwise.

Every part of a multipart upload except the last SHALL be exactly the configured part size, because some stores require all parts but the last to be equal in size.

#### Scenario: A small object is one request
- **WHEN** a chunk stream ends within one part size
- **THEN** it is written with a single `PutObject`, because a multipart upload below the minimum part size is refused by the store outright

#### Scenario: Successful multipart upload
- **WHEN** a chunk stream totalling more than one part size is uploaded
- **THEN** the completed object's bytes equal the concatenated stream

#### Scenario: Parts are uniformly sized
- **WHEN** a chunk stream whose chunk boundaries do not align with the part size is uploaded
- **THEN** every part except the last is exactly the part size, with a straddling chunk split across the boundary rather than overshooting it

#### Scenario: Response metadata survives the round trip
- **WHEN** an object is written with a content type, cache control and an ETag
- **THEN** a subsequent HEAD reports all three, by either upload path

#### Scenario: Abort on failure
- **WHEN** the chunk stream raises, throws or exits mid-upload, or a part is rejected
- **THEN** the multipart upload is aborted, leaving neither a readable object nor a pending upload accruing storage

#### Scenario: The chunk source is released exactly once
- **WHEN** an upload ends by any route — completion, a raising stream, or a failure before the first part
- **THEN** the source stream's cleanup runs once, so a render is neither leaked nor torn down twice
