## 1. Profiles

- [x] 1.1 `AudioProxy.Config`: `AP_VARIANT_S3_*` group (endpoint, addressing, CA bundle, credential triple + session token), per-variable fallback, group-atomic credential validation naming missing vars
- [x] 1.2 S3 client config assembly becomes profile-parameterized; `VariantStore.S3` takes the store profile (probe, HEAD, multipart, presign)

## 2. Tests

- [x] 2.1 No-override equivalence: with no `AP_VARIANT_S3_*` set, the config and every store operation are byte-identical to before (pinning test)
- [x] 2.2 Partial-credential boot failures name the missing variables; addressing derives per side
- [x] 2.3 Split principals against MinIO (two users: read-only source, writing store): render-from-S3 + write-back completes; source principal never touches the store (assert via MinIO audit/request capture)
- [x] 2.4 Cross-endpoint: store on the fake S3, sources on MinIO; redirect-mode presign resolves against the store endpoint (`@tag :minio`)

## 3. Docs

- [x] 3.1 README configuration table: the override group as one row group with the fallback rule stated once
- [x] 3.2 `docs/s3-providers.md`: a worked cross-provider example (R2 sources, AWS store)
