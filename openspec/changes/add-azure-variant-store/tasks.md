# Tasks

## 1. Store

- [ ] 1.1 `AudioProxy.Config`: store-URL parsing accepts `azblob://container`; boot aborts if the `AP_AZURE_*` group is absent
- [ ] 1.2 `VariantStore.Azblob`: the five callbacks over `AudioProxy.Azure` — `head/1`, `get_stream/2`, `put_stream/3`, `presign/2`, `capabilities/0`; header/metadata mapping to blob properties and `x-ms-meta-*`
- [ ] 1.3 Boot writability probe against the container under the Azure client

## 2. Tests

- [ ] 2.1 MISS → tee → HIT round-trip against Azurite (`@tag :azurite`), redirect and proxy modes; HIT redirect's SAS URL serves 206 on Range
- [ ] 2.2 Header round-trip: content type and cache control identical between the rendering response and the stored-variant response
- [ ] 2.3 Abandoned render: kill mid-tee, assert the key stays absent (no commit) and the next request re-renders
- [ ] 2.4 Coalesced double-request against an `azblob://` store: one render, both clients served, one object written
- [ ] 2.5 Boot: `azblob://` store without the group aborts naming it

## 3. Docs

- [ ] 3.1 README variant-store section and `AP_VARIANT_STORE` row mention `azblob://`; fully-on-Azure worked example (sources + store)
- [ ] 3.2 Docs site rendering/sources guides follow via the drift notifier
