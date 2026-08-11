## ADDED Requirements

### Requirement: Azure Blob variant store
The system SHALL accept `AP_VARIANT_STORE=azblob://container`, running every store operation — boot writability probe, HEAD, block-staged streaming write-back committed with content type/cache control/metadata, SAS-based HIT redirects, proxy-mode ranged reads — through the Azure client, and SHALL abort boot when an `azblob://` store is configured without the `AP_AZURE_*` group.

#### Scenario: MISS renders and writes back to Azure
- **WHEN** a request misses an `azblob://` store
- **THEN** the response streams as 200 chunked while the render tees block-staged into the container, and a subsequent identical request is a HIT

#### Scenario: HIT redirects to a SAS URL
- **WHEN** a request hits an `azblob://` store in redirect mode
- **THEN** the response is a 302 whose Location is a SAS URL against which Azure serves Range/206 directly

#### Scenario: Headers survive the round-trip
- **WHEN** a variant written back with a content type and cache control is later served from the store
- **THEN** both headers match what the original render's response carried

#### Scenario: A partial render is never a HIT
- **WHEN** a render is abandoned after staging blocks but before commit
- **THEN** the store reports the key absent and the next request renders; the uncommitted blocks are Azure's to garbage-collect

#### Scenario: Store without credentials aborts boot
- **WHEN** `AP_VARIANT_STORE=azblob://variants` is set and no `AP_AZURE_*` group is configured
- **THEN** boot aborts naming the missing group
