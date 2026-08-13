## ADDED Requirements

### Requirement: The store's identity is the store's configuration
All variant-store S3 operations — the boot writability probe, HEAD lookups, multipart write-back, and presigned HIT URLs — SHALL use the store-side profile; a redirect-mode presign SHALL be valid against the store's endpoint and credentials even when they differ from the source side's.

#### Scenario: Redirect HIT under split configuration
- **WHEN** sources and store use different providers and a HIT is served in redirect mode
- **THEN** the `302` Location is presigned for the store's provider and fetches successfully

#### Scenario: Split principals
- **WHEN** the source credential can only read and the variant credential can write
- **THEN** renders from S3 sources complete and write back; the source credential is never used for a store operation
