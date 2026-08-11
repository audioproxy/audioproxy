# Tasks

## 1. Store

- [ ] 1.1 `AudioProxy.Config`: store-URL parsing accepts `gcs://bucket`; boot aborts if the `AP_GCS_*` group is absent
- [ ] 1.2 `VariantStore.S3` threads the client profile; `gcs://` stores run under `:gcs` (probe, HEAD, put_stream, presign, get_stream)

## 2. Tests

- [ ] 2.1 MISS → tee → HIT round-trip against the S3 fake/MinIO via `AP_GCS_ENDPOINT` (`@tag :minio`), both redirect and proxy modes
- [ ] 2.2 Cross-provider: sources on the shared profile's endpoint, store on the GCS profile's — one render, two origins, asserted per side
- [ ] 2.3 Metadata round-trip (content type, cache control) through a `gcs://` store object
- [ ] 2.4 Boot: `gcs://` store without the group aborts naming it; writability probe runs under the profile
- [ ] 2.5 Manual smoke against live GCS: MISS → write-back → HIT redirect, including one variant above the multipart threshold; result recorded in the PR

## 3. Docs

- [ ] 3.1 README variant-store section and `AP_VARIANT_STORE` row mention `gcs://`
- [ ] 3.2 `docs/s3-providers.md`: cross-provider example (AWS sources, GCS variants)
