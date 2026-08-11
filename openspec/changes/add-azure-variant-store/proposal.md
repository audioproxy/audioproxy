# Add Azure Blob Variant Store

## Why

The Azure track's end state is a deployment living entirely on Azure — sources in one container, rendered variants cached in another — with no S3-shaped configuration anywhere. `add-azure-client` built the storage operations and `add-azure-source-backend` the read side; this slice makes `azblob://` a write-back target. The client's `put_stream/4` (block staging) was designed for exactly the tee's progressive chunks, so the store backend is contract plumbing over an existing facade, the same shape `VariantStore.S3` has over `AudioProxy.S3`.

## What Changes

- `AP_VARIANT_STORE=azblob://container` is accepted; a `VariantStore.Azblob` backend implements the five store callbacks over `AudioProxy.Azure`: `head/1`, `get_stream/2` (proxy mode), `put_stream/3` (the tee's write-back), `presign/2` (HIT redirect → SAS URL), `capabilities/0`.
- Response-header round-trip through blob properties and `x-ms-meta-*`: content type and cache control set at commit, recovered by `head/1` — same guarantee the S3 store gives.
- The boot writability probe runs against the container; an `azblob://` store with no `AP_AZURE_*` group configured aborts boot.
- HIT serving works in both modes: 302 to a SAS URL (redirect, the default — S3/CDN-style Range/206 comes from Azure directly) and proxy mode.
- Docs: README variant-store section and `AP_VARIANT_STORE` row, plus a fully-on-Azure worked example (azblob sources + azblob store).

## Non-goals

- Retention/eviction — `split-retention-cap` owns that story regardless of backend.
- Access-tier management (hot/cool/archive) — variants are hot by definition of being a cache; an archived variant is a deleted one that costs money.
- A credential split between Azure sources and an Azure store — `split-s3-credentials`' pattern, on demand.

## Capabilities

### New Capabilities

<!-- none -->

### Modified Capabilities

- `variant-cache`: an `azblob://container` store URL, backed by the Azure client — block-staged streaming write-back, SAS-based HIT redirects, metadata round-trip.

## Impact

- New: `VariantStore.Azblob`. Modified: `AudioProxy.Config` (store-URL parsing accepts `azblob://`), boot probe, README.
- Hard dependency: `add-azure-client`. Independent of `add-azure-source-backend` — either lands first, or both in parallel worktrees.
- Tests run the full MISS → tee → HIT lifecycle against Azurite (`@tag :azurite`), both serve modes, including a coalesced double-request and an abandoned-render case (uncommitted blocks are Azure's to garbage-collect; the store must simply not serve a partial).
- Estimated ~250 LOC including tests.
- Position: with the Azure track, same trigger as its siblings.
