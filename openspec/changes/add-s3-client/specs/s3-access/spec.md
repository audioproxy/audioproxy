## ADDED Requirements

### Requirement: Presigned GET URLs
The system SHALL generate SigV4 presigned GET URLs for S3 objects with a configurable expiry, valid against AWS S3 and S3-compatible endpoints (custom endpoint/region, path-style addressing for custom endpoints).

#### Scenario: Signature correctness
- **WHEN** presigning a known request with the AWS SigV4 test-suite credentials and timestamp
- **THEN** the query parameters (`X-Amz-Signature` et al.) match the published known-answer values

#### Scenario: Expiry honored
- **WHEN** a URL is presigned with a 300 s expiry
- **THEN** `X-Amz-Expires=300` is present and the URL is rejected by the store after expiry

#### Scenario: Key escaping
- **WHEN** presigning a key containing spaces, `+`, or unicode
- **THEN** the canonical request uses correct URI encoding and the URL fetches the object

### Requirement: Object metadata via HEAD
The system SHALL check object existence returning size and ETag, distinguishing not-found from other failures (auth, network).

#### Scenario: Existing object
- **WHEN** HEAD is issued for an existing object
- **THEN** `{:ok, %{size: n, etag: e}}` is returned

#### Scenario: Missing object
- **WHEN** HEAD is issued for a missing key
- **THEN** `{:error, :not_found}` is returned (mapped to 404 upstream)

### Requirement: Streaming multipart upload
The system SHALL upload a stream of chunks of unknown total length to a bucket/key via S3 multipart upload, aborting the multipart upload on failure so no orphaned parts accrue.

#### Scenario: Successful upload
- **WHEN** a chunk stream totalling more than one part size is uploaded
- **THEN** the completed object's bytes equal the concatenated stream

#### Scenario: Abort on failure
- **WHEN** the chunk stream errors mid-upload
- **THEN** the multipart upload is aborted (no incomplete-part storage leak)
