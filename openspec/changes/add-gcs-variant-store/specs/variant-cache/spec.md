## ADDED Requirements

### Requirement: GCS variant store
The system SHALL accept `AP_VARIANT_STORE=gcs://bucket`, running every store operation — boot writability probe, HEAD, streaming write-back (single PUT below the part threshold, S3-compatible multipart above it), presigned HIT redirect, proxy-mode ranged reads — under the GCS client profile, and SHALL abort boot when a `gcs://` store is configured without the `AP_GCS_*` group.

#### Scenario: MISS renders and writes back to GCS
- **WHEN** a request misses a `gcs://` store
- **THEN** the response streams as 200 chunked while the render tees into the GCS bucket, and a subsequent identical request is a HIT

#### Scenario: HIT redirects to a GCS presigned URL
- **WHEN** a request hits a `gcs://` store in redirect mode
- **THEN** the response is a 302 whose Location is a presigned URL against the GCS endpoint

#### Scenario: Store without credentials aborts boot
- **WHEN** `AP_VARIANT_STORE=gcs://variants` is set and no `AP_GCS_*` group is configured
- **THEN** boot aborts naming the missing group

#### Scenario: Cross-provider deployment
- **WHEN** sources resolve via the shared S3 profile and the store is `gcs://`
- **THEN** source reads sign under the shared profile and store writes under the GCS profile in the same render
