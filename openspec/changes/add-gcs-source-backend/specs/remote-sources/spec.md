## ADDED Requirements

### Requirement: GCS source scheme
The system SHALL accept `gcs://bucket/key` sources, split at the first `/` with both halves required, the key kept as raw decoded bytes, bucket bounded at 63 bytes and key at 1024 (GCS's own maxima), with the whole body bounded before it is split — semantics identical to `s3://` except for the scheme and the client profile the storage seam signs under.

#### Scenario: GCS source renders
- **WHEN** a signed request names `gcs://masters/2026/piece.wav` and the `AP_GCS_*` group is configured
- **THEN** `stat/1` answers from a HEAD against the GCS endpoint and `ffmpeg_input/1` is a presigned GET URL ffmpeg Range-reads directly

#### Scenario: Unconfigured group refused
- **WHEN** a `gcs://` source arrives and no `AP_GCS_*` group is set
- **THEN** the response is 500 `:not_configured`, mirroring `s3://` without credentials

#### Scenario: Bucket allowlisted
- **WHEN** `AP_SOURCE_ALLOWLIST` is set and does not match the source's bucket
- **THEN** the response is 404, indistinguishable from a missing object

#### Scenario: Distinct cache identity
- **WHEN** `gcs://b/k` and `s3://b/k` are both requested
- **THEN** their canonical identity strings differ and they occupy distinct cache keys
