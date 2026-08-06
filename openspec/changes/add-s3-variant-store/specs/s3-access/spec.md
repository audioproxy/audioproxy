## ADDED Requirements

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
