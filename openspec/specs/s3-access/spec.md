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

`{:http, status, _}` carries an **unbounded** status, so the mapping SHALL be total over the statuses a store can answer an error with, not only over the ranges someone enumerated. A redirect (3xx) SHALL answer 500 as a misconfiguration rather than the upstream-failure row: the client never follows it, and retrying a store that redirects because the configured region or endpoint is not the object's does not succeed.

#### Scenario: Denied credential is indistinguishable from a missing object
- **WHEN** the bucket policy denies HEAD for an object that exists
- **THEN** the response is byte-identical to the 404 for an object that does not, and the log names `access_denied`

#### Scenario: Store outage
- **WHEN** S3 answers 5xx or the request fails at the transport
- **THEN** the response is the upstream-failure row, not a 404

#### Scenario: Unconfigured client
- **WHEN** an `s3://` source is requested with no credentials configured
- **THEN** the response is 500, since no client action can resolve it

#### Scenario: Wrong region
- **WHEN** the store answers a HEAD with a redirect because the configured region or endpoint is not the object's
- **THEN** the response is 500, not the upstream-failure row and not a raised `FunctionClauseError`

#### Scenario: No status is left unclassified
- **WHEN** the mapping is exercised across every status a store can answer an error with
- **THEN** each one yields a reason with a row, so a gap between range guards fails a test rather than a request

### Requirement: The variant store is a consumer of this layer
The system SHALL implement the variant-store backend for `s3://` on top of this layer's four operations, mapping the seam's metadata onto the object itself — `Content-Type` and `Cache-Control` as real headers, anything else as user metadata — rather than into a sidecar object. An upload SHALL be its own commit point, so no staging key is written and a failed upload leaves nothing readable.

#### Scenario: Metadata survives a redirect
- **WHEN** a cached variant is fetched directly from the store via a presigned URL
- **THEN** its `Content-Type` and `Cache-Control` are the ones the proxy would have sent, because they are the object's own headers

#### Scenario: Interrupted upload leaves no partial variant
- **WHEN** a write-back fails partway
- **THEN** no object is readable under that cache key, and a later request is an ordinary miss rather than a truncated hit

#### Scenario: An object nobody stored as a variant is not one
- **WHEN** an object exists under a cache key but is missing any of the variant metadata, or carries it empty
- **THEN** every read callback reports it as a miss rather than serving it with invented headers, because a redirected client fetches it with no proxy in the path to correct them
- **AND** the callbacks agree: one answering with bytes while another calls the key absent would be the backends disagreeing about whether a variant is stored

### Requirement: A store failure degrades the cache, not the request
The system SHALL treat a variant-store lookup failure this layer cannot express — an outage, a misconfiguration, a refused credential — as a cache miss, so the request renders rather than failing on the cache's behalf. It SHALL classify the failure by the same table the source backend uses rather than a second one, differing only where a store and a source read the same status differently, and SHALL log anything that is not an ordinary miss with the bucket and key, with any value the system did not itself construct redacted.

#### Scenario: An unreachable variant store still serves audio
- **WHEN** the variant store cannot be reached on a HIT check
- **THEN** the request renders and the client receives correct bytes, and the failure and its classification appear in the log

#### Scenario: A 404 means something different to a store than to a source
- **WHEN** a status that names the container rather than the object reaches the classifier
- **THEN** it is a misconfiguration rather than an ordinary miss, because a bucket the operator configured being absent is not the same fact as a variant not being cached yet

#### Scenario: A bucket that disappears after boot reads as a cold cache
- **WHEN** the variant bucket is deleted while the system is running
- **THEN** reads report ordinary misses and every request renders, because the store answers a missing bucket and a missing object with the same bodyless `404` and the distinguishing code is never on the wire
- **AND** the write-back is the operation that surfaces it, since only a write receives an error body

