## ADDED Requirements

### Requirement: Presigned GET URLs
The system SHALL generate SigV4 presigned GET URLs for S3 objects with a configurable expiry, valid against AWS S3 and S3-compatible endpoints (custom endpoint and region).

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

### Requirement: Object metadata via HEAD
The system SHALL check object existence returning size, ETag and stored metadata, distinguishing not-found from other failures (auth, network, misconfiguration).

#### Scenario: Existing object
- **WHEN** HEAD is issued for an existing object
- **THEN** its size, ETag, content type, cache control and user metadata are returned

#### Scenario: Missing object
- **WHEN** HEAD is issued for a missing key
- **THEN** `{:error, :not_found}` is returned

#### Scenario: Rejected credentials are not a miss
- **WHEN** a request is made with credentials the store rejects
- **THEN** `{:error, :access_denied}` is returned rather than `:not_found`, so an expired credential cannot be read as a cold cache

#### Scenario: Unconfigured credentials are refused locally
- **WHEN** an operation is attempted with no credentials configured
- **THEN** `{:error, :not_configured}` is returned without a request being made, so no credential-provider chain can substitute something the operator did not set

### Requirement: Streaming upload of unknown length
The system SHALL upload a stream of chunks whose total length is not known in advance, choosing a single-request upload for a stream that fits within one part and a multipart upload otherwise.

#### Scenario: A small object is one request
- **WHEN** a chunk stream ends within one part size
- **THEN** it is written with a single `PutObject`, because a multipart upload below the minimum part size is refused by the store outright

#### Scenario: Successful multipart upload
- **WHEN** a chunk stream totalling more than one part size is uploaded
- **THEN** the completed object's bytes equal the concatenated stream

#### Scenario: Response metadata survives the round trip
- **WHEN** an object is written with a content type, cache control and an ETag
- **THEN** a subsequent HEAD reports all three, by either upload path

#### Scenario: Abort on failure
- **WHEN** the chunk stream raises, throws or exits mid-upload, or a part is rejected
- **THEN** the multipart upload is aborted, leaving neither a readable object nor a pending upload accruing storage

#### Scenario: The chunk source is released exactly once
- **WHEN** an upload ends by any route — completion, a raising stream, or a failure before the first part
- **THEN** the source stream's cleanup runs once, so a render is neither leaked nor torn down twice

### Requirement: Bounded reads
The system SHALL read an object, or an inclusive byte range of it, as a lazy stream that never holds the whole object in memory.

#### Scenario: Whole object
- **WHEN** an object is read with no range
- **THEN** its bytes are returned in order, in bounded chunks

#### Scenario: Range honored
- **WHEN** an inclusive range is requested
- **THEN** exactly those bytes are returned, and a range extending past the end is truncated to the object's length

#### Scenario: Unsatisfiable range
- **WHEN** a range starts at or past the end of the object, or is inverted
- **THEN** `{:error, :invalid_range}` is returned before any read begins, rather than failing partway through a response
