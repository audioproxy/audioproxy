## ADDED Requirements

### Requirement: Azure Blob client facade
The system SHALL provide an Azure Blob client with the surface `head/2`, `presign_get/3`, `put_stream/4`, `delete/2`, `get_stream/3`, and `configured?/0` over container/blob pairs, authenticating every operation via a locally-computed service SAS (no SDK, no new dependencies), with typed errors keeping `:not_found` and `:access_denied` distinct and an `{:http, status, body}` escape hatch mapped without catch-alls by consumers.

#### Scenario: HEAD reports size and ETag
- **WHEN** `head/2` is called for an existing blob
- **THEN** it returns the blob's size, ETag, content type, cache control, and `x-ms-meta-*` metadata with the prefix stripped

#### Scenario: Presigned GET is Range-capable
- **WHEN** `presign_get/3` mints a URL and a client issues a Range request against it
- **THEN** the blob service answers 206 with the requested bytes, no proxy involvement

#### Scenario: Streaming write commits with metadata
- **WHEN** `put_stream/4` consumes a chunk stream
- **THEN** blocks are staged as they arrive and one commit sets content type, cache control, and metadata, after which `head/2` reports all three

#### Scenario: Missing blob is not access denied
- **WHEN** a blob does not exist versus when the SAS lacks permission
- **THEN** the client returns `:not_found` and `:access_denied` respectively, never folded

### Requirement: Group-atomic Azure configuration
The system SHALL read `AP_AZURE_ACCOUNT` and `AP_AZURE_KEY` as a both-or-neither group, aborting boot on a strict subset naming the missing variable, with optional `AP_AZURE_ENDPOINT` switching URL assembly from account-in-host (`https://{account}.blob.core.windows.net`) to account-in-path (Azurite's shape) while SAS signing remains identical in both.

#### Scenario: Partial group refused at boot
- **WHEN** `AP_AZURE_ACCOUNT` is set without `AP_AZURE_KEY`
- **THEN** boot aborts naming the incomplete group

#### Scenario: Emulator endpoint
- **WHEN** `AP_AZURE_ENDPOINT` points at an Azurite origin
- **THEN** every facade operation succeeds against it with account-in-path URLs and the same signatures

### Requirement: Pinned API version with known-answer vectors
The client SHALL pin one `x-ms-version`, build the SAS string-to-sign for exactly that version, and carry known-answer test vectors for it, so that a version bump fails tests until the string-to-sign is updated deliberately.

#### Scenario: Vector mismatch fails
- **WHEN** the string-to-sign construction drifts from the pinned version's field list
- **THEN** the known-answer vectors fail regardless of whether an emulator would have accepted the signature
