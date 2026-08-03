## 1. Addressing

- [x] 1.1 `AP_S3_ADDRESSING` in `AudioProxy.Config`: `path` | `virtual`, defaulting to `virtual` with no `AP_S3_ENDPOINT` and `path` with one, refused at boot for any other value
- [x] 1.2 Thread it into `AudioProxy.S3.config/0` as `virtual_host: true`, which is where the *request* path reads it
- [x] 1.3 Thread it into the `ExAws.S3.presigned_url/5` options, which is where the *presign* path reads it — a separate source, and the two disagreeing produces URLs no store can verify
- [x] 1.4 Unit tests asserting the built URL for both styles and both call sites: `bucket.host` under `virtual`, bucket-leading path under `path`, and the presigned URL agreeing with the request in each case
- [x] 1.5 Config tests for both defaults and the refusal, including that a `virtual` default with no endpoint does not depend on `AP_S3_ENDPOINT` being absent by accident

## 2. Exact-size multipart parts

- [x] 2.1 Rework `into_parts/1` to emit exactly `@part_size` bytes per part, carrying the remainder of a straddling chunk forward; the final part keeps whatever is left
- [x] 2.2 Test against MinIO with chunk sizes that do not divide the part size, asserting byte-equality on the round trip and that every part but the last is exactly the part size
- [x] 2.3 Confirm the memory bound is unchanged — one part plus one chunk — and that the single-`PutObject` fast path and the exactly-one-part-boundary case still behave

## 3. TLS trust

- [x] 3.1 `AP_S3_CA_BUNDLE` in `AudioProxy.Config`: an existing readable file, validated at boot
- [x] 3.2 `AudioProxy.S3.HttpClient.ssl_options/1` uses `cacertfile:` when set and `cacerts:` otherwise, never both
- [x] 3.3 Tests for the default path and the configured path, plus the boot refusal for an unreadable file

## 4. Correct the record

- [x] 4.1 `AudioProxy.S3`'s moduledoc: it currently claims virtual-hosted for AWS and path-style for custom endpoints, which was never true — replace with what the configuration now actually does
- [x] 4.2 README: `AP_S3_ADDRESSING` and `AP_S3_CA_BUNDLE` in the config table, and correct the same false claim in *S3 credentials*
- [x] 4.3 `docs/s3-providers.md`: correct the addressing claim, add Tigris on Fly (`https://fly.storage.tigris.dev`, `AWS_REGION=auto`, `AP_S3_ADDRESSING=virtual`, and the `AWS_ENDPOINT_URL_S3` → `AP_S3_ENDPOINT` mapping `fly storage create` leaves behind), and drop the part-size and CA-bundle entries from the limitations list now that both are fixed
- [x] 4.4 State plainly in `docs/s3-providers.md` that virtual-hosted addressing is asserted at the URL level but not exercised against a live store in CI, since neither Tigris nor AWS is reachable from it

## 5. Verify

- [x] 5.1 Full suite green including `--include minio`: MinIO keeps working path-style, which is the regression this change must not cause
- [ ] 5.2 Manual check against the client's real Tigris bucket — a render, a write-back and a presigned fetch — and record the result, since it is the only evidence virtual-hosted addressing works end to end
