# Tasks

## 1. Profile

- [ ] 1.1 `AudioProxy.Config`: `AP_GCS_*` group (key id + secret both-or-neither, endpoint defaulting to `https://storage.googleapis.com`, path-style addressing), boot validation naming the incomplete group
- [ ] 1.2 `AudioProxy.S3` signs under a passed profile; `:gcs` profile assembly (inherit the parameterization from `split-s3-credentials` if it landed first, introduce it here otherwise)

## 2. Scheme

- [ ] 2.1 `AudioProxy.Source.Gcs`: `parse/1` (first-`/` split, both halves required, 63/1024 bounds enforced before the split), `canonical/1` distinct from `s3://`, `tag/0`, `scheme/0`
- [ ] 2.2 `authorize/1` against `AP_SOURCE_ALLOWLIST` (bucket match, refusal → 404)
- [ ] 2.3 `stat/1` = `S3.head/2` under `:gcs`; `ffmpeg_input/1` = `S3.presign_get/3` under `:gcs`; error mapping identical to `Source.S3`'s (no catch-all)
- [ ] 2.4 Register in the resolver dispatch table

## 3. Tests

- [ ] 3.1 Parse/canonical/bounds property tests mirroring `Source.S3`'s; cache-key round-trip; `gcs://b/k` ≠ `s3://b/k` identity
- [ ] 3.2 Profile independence: shared group at one fake endpoint, `AP_GCS_ENDPOINT` at another; each scheme's requests hit its own origin
- [ ] 3.3 End-to-end render from a `gcs://` source with `AP_GCS_ENDPOINT` pointed at the suite's S3 fake/MinIO (`@tag :minio`)
- [ ] 3.4 Boot validation: partial group aborts naming variables; unconfigured group → 500 on request
- [ ] 3.5 Manual smoke against live GCS interop (HEAD + presigned render), result recorded in the PR description — CI cannot assert Google's endpoint

## 4. Docs

- [ ] 4.1 `docs/s3-providers.md`: GCS section — interop route (`AP_S3_ENDPOINT`) for GCS-only, `gcs://` scheme for mixed; HMAC key creation pointer
- [ ] 4.2 API doc §1 scheme table + README sources section + configuration table (`AP_GCS_*` rows) + `llms-full.txt` scheme list
- [ ] 4.3 Docs site sources guide gains the scheme (audioproxy-docs repo; drift notifier will also flag it)
