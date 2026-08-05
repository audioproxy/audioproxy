## 1. The backend

- [ ] 1.1 `VariantStore.S3`: `head/1` via `S3.head/2`, `get_stream/2` via `S3.get_stream/3` (range through), `put_stream/3` via `S3.put_stream/4`
- [ ] 1.2 Metadata onto the object — `content_type` and `cache_control` as real headers, the rest as `x-amz-meta-*` — and read back off the HEAD in `head/1`
- [ ] 1.3 `presign/2` via `S3.presign_get/3` with `AP_PRESIGN_TTL`; `capabilities/0` returns `[:presign]`
- [ ] 1.4 Classify this layer's failures per `add-s3-source-backend`'s table, reusing it rather than restating it

## 2. Configuration

- [ ] 2.1 `Config`: accept `s3://bucket`, replacing the raise; reject a path, query or fragment on the URL the way the `file://` branch does
- [ ] 2.2 Boot-time writability probe — a small PUT and DELETE under a reserved key prefix — so a bucket that refuses writes fails the container rather than silently discarding write-backs
- [ ] 2.3 Confirm `validate!/1` now admits `AP_SERVE_MODE=redirect` with an `s3://` store, and still refuses it with `file://`, without changes to the validator

## 3. Parity suite

- [ ] 3.1 Extract the seam assertions from the local backend's tests into one suite parameterised by backend: round-trip bytes and metadata, ranged read, miss on an absent key, failed write leaves the response intact
- [ ] 3.2 Run it against `file://` and against MinIO; leave backend-specific mechanisms (the `tmp/` sweep, the sidecar) in the local suite
- [ ] 3.3 End-to-end redirect mode: a HIT answers `302` with `no-store`, and following the `Location` delivers the variant with the same `Content-Type` and `Cache-Control` a proxied HIT would have sent

## 4. Docs

- [ ] 4.1 README: `AP_VARIANT_STORE=s3://bucket` in the config table and the Variant store section; redirect mode is reachable, and why it is the default
- [ ] 4.2 `docs/audio-proxy-api-v1.md` §6: drop the "S3 backend pending" hedge
- [ ] 4.3 `docs/s3-providers.md`: note any provider whose presigned-URL or metadata behaviour differs for variant serving
