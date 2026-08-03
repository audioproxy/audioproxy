# s3-access Specification

## Purpose

What the proxy needs from object storage, and nothing more: a URL a client or
ffmpeg can fetch without credentials of its own, an existence check, a write of
unknown length, and a bounded read. Four operations, deliberately, so that "we
only do these four things" is enforced by the surface rather than merely
intended.

Two distinctions in here are load-bearing and easy to erase by accident.

**A missing object is not a rejected credential.** Stores make them genuinely
ambiguous — AWS answers 403 for a missing object when the caller cannot list the
bucket — but collapsing them turns an expired key into a permanently cold cache:
every read a miss, every miss a re-render, every write-back failing silently.
The same logic extends to a misconfigured bucket and to credentials that were
never set, which is why an unconfigured client refuses locally instead of
letting a provider chain reach for something the operator did not choose.

**An upload that does not complete leaves nothing.** Not just no readable
object: no *pending* upload either. Incomplete multipart uploads are invisible
to both a HEAD and a bucket listing, and are billed until a lifecycle rule
removes them, so "it failed and the object isn't there" is not evidence that
nothing was left behind. The abort is the requirement; the absent object is a
consequence.

The choice of upload path — one request or a multipart sequence — is not an
optimisation. A multipart upload below the store's minimum part size is refused
outright, and previews are most of what this proxy renders, so the single-request
path is what makes small variants writable at all.

Signing correctness is verified against a real S3-compatible store rather than
against a stub. A stub cannot reject a signature, so it cannot tell a correct
request from a self-consistently wrong one.
## Requirements
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

