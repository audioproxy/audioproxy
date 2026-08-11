# Tasks

## 1. Scheme

- [ ] 1.1 `AudioProxy.Source.Azblob`: `parse/1` (first-`/` split, both halves required, 63/1024 bounds enforced before the split), `canonical/1`, `tag/0`, `scheme/0`
- [ ] 1.2 `authorize/1` against `AP_SOURCE_ALLOWLIST` (container match, refusal → 404)
- [ ] 1.3 `stat/1` = `Azure.head/2`; `ffmpeg_input/1` = `Azure.presign_get/3`; exhaustive error mapping, no catch-all (`:not_found`/`:access_denied`/4xx → 404 blind row, `:not_configured` → 500, 5xx → 502)
- [ ] 1.4 Register in the resolver dispatch table

## 2. Tests

- [ ] 2.1 Parse/canonical/bounds property tests mirroring `Source.S3`'s; cache-key round-trip; pairwise-distinct identities across `s3://`/`gcs://`/`azblob://`
- [ ] 2.2 End-to-end render from an `azblob://` source against Azurite (`@tag :azurite`), including a trimmed render proving Range reads work through the SAS URL
- [ ] 2.3 `/info` from an `azblob://` source: size and ETag-derived validator
- [ ] 2.4 Allowlist refusal → 404; unconfigured group → 500; missing blob and wrong-credential cases both → 404

## 3. Docs

- [ ] 3.1 API doc §1 scheme table + README sources section + `llms-full.txt` scheme list
- [ ] 3.2 Docs site sources guide gains the scheme (audioproxy-docs repo; drift notifier will also flag it)
