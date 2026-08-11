## ADDED Requirements

### Requirement: Azure Blob source scheme
The system SHALL accept `azblob://container/blob` sources, split at the first `/` with both halves required, the blob name kept as raw decoded bytes, container bounded at 63 bytes and blob name at 1024, the whole body bounded before the split, with `stat/1` answering from a HEAD and `ffmpeg_input/1` a SAS GET URL, and error mapping exhaustive with access-denied folded into the blind 404 row.

#### Scenario: Azure source renders
- **WHEN** a signed request names `azblob://masters/2026/piece.wav` and the `AP_AZURE_*` group is configured
- **THEN** the render's input is a SAS URL ffmpeg Range-reads directly, and `stat/1`'s size answers the 413 check before any subprocess starts

#### Scenario: Unconfigured group refused
- **WHEN** an `azblob://` source arrives and no `AP_AZURE_*` group is set
- **THEN** the response is 500 `:not_configured`

#### Scenario: Container allowlisted
- **WHEN** `AP_SOURCE_ALLOWLIST` is set and does not match the source's container
- **THEN** the response is 404, indistinguishable from a missing blob

#### Scenario: Distinct cache identity
- **WHEN** `azblob://c/k`, `s3://c/k`, and `gcs://c/k` are each requested
- **THEN** their canonical identity strings differ pairwise and each occupies its own cache key
