## ADDED Requirements

### Requirement: The variant store is a consumer of this layer
The system SHALL implement the variant-store backend for `s3://` on top of this layer's four operations, mapping the seam's metadata onto the object itself — `Content-Type` and `Cache-Control` as real headers, anything else as user metadata — rather than into a sidecar object. An upload SHALL be its own commit point, so no staging key is written and a failed upload leaves nothing readable.

#### Scenario: Metadata survives a redirect
- **WHEN** a cached variant is fetched directly from the store via a presigned URL
- **THEN** its `Content-Type` and `Cache-Control` are the ones the proxy would have sent, because they are the object's own headers

#### Scenario: Interrupted upload leaves no partial variant
- **WHEN** a write-back fails partway
- **THEN** no object is readable under that cache key, and a later request is an ordinary miss rather than a truncated hit
