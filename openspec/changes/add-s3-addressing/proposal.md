## Why

A client deployment needs this proxy on Fly.io with Tigris buckets, and **it cannot talk to Tigris at all**. Tigris requires virtual-hosted addressing (`bucket.fly.storage.tigris.dev`) for every bucket created after 19 February 2025 and is withdrawing path-style support for new buckets; `AudioProxy.S3` sends path-style whenever `AP_S3_ENDPOINT` is set, with no way to ask for anything else.

Investigating that turned up a larger problem. `ex_aws` addresses **every** request path-style unless its config carries `virtual_host: true` — `ExAws.Operation.S3.add_bucket_to_path/2`'s fallback clause puts the bucket in the path, and nothing in `add-s3-client` sets that flag. So:

- `AudioProxy.S3`'s moduledoc, the README's *S3 credentials* section and `docs/s3-providers.md` all state that addressing is virtual-hosted for AWS and path-style only for custom endpoints. **That is false.** It is path-style everywhere.
- AWS deprecated path-style addressing, and regions launched after 2019 do not support it. The AWS path — no `AP_S3_ENDPOINT` — is therefore not merely untested, it is likely broken against any modern bucket.

Addressing was never a decision this codebase made; it was a default nobody looked at. This change makes it one.

## What Changes

- **`AP_S3_ADDRESSING`**, taking `path` or `virtual`. Defaults to `path` when `AP_S3_ENDPOINT` is set — preserving today's working behaviour for MinIO, Ceph, Backblaze B2, DigitalOcean Spaces, Scaleway and Hetzner — and to `virtual` when it is not, which is what AWS now requires.
- Thread the choice into **both** places `ex_aws` reads it. The request path takes `virtual_host: true` from the config map; `ExAws.S3.presigned_url/5` reads `:virtual_host` from its *options* instead. Set one and not the other and presigned URLs address a different host than requests do — and the host is inside the signature, so every presigned URL fails.
- **Exact-size multipart parts.** `into_parts/1` currently flushes when the buffer *reaches* 5 MiB, so parts vary in size with chunk boundaries. Cloudflare R2 requires every part but the last to be equal, and this is the direction other stores are moving. Splitting a chunk at the boundary fixes it and costs nothing.
- **`AP_S3_CA_BUNDLE`**, so a self-hosted MinIO or Ceph behind a private CA can be reached over `https://` rather than forced onto `http://`. `AudioProxy.S3.HttpClient` hardcodes the system trust store today.
- **Correct the three documents** that state the false addressing claim, and add Tigris to `docs/s3-providers.md` — which cannot honestly be written until this lands.

Not breaking: every currently working configuration keeps working, because the default for a custom endpoint is the behaviour it has today.

## Capabilities

### New Capabilities

<!-- none — this changes how an existing capability behaves, not what the proxy can do -->

### Modified Capabilities

- `s3-access`: request addressing becomes a configured choice rather than an unexamined default; multipart parts become uniformly sized; TLS trust becomes configurable.

## Impact

- **Code:** `AudioProxy.S3` (`config/0`, the presign path, `into_parts/1`), `AudioProxy.S3.HttpClient` (`ssl_options/1`), `AudioProxy.Config` (two new variables and their boot validation).
- **Config surface:** `AP_S3_ADDRESSING`, `AP_S3_CA_BUNDLE`. Both optional; both `AP_`-prefixed per §6.
- **Docs:** `README.md` (config table, *S3 credentials*), `docs/s3-providers.md` (correct the addressing claim, add Tigris, drop the CA-bundle and part-size entries from the limitations list), `AudioProxy.S3`'s moduledoc.
- **Dependencies:** none added. `ex_aws` already supports both addressing styles.
- **Depends on:** `add-s3-client` (merged, PR #34) for `AudioProxy.S3`, `AudioProxy.S3.HttpClient` and the `AWS_*`/`AP_S3_ENDPOINT` surface.
- **Testing limits worth stating up front:** neither Tigris nor AWS can be reached from CI, so the addressing decision has to be pinned by asserting on the URL that gets built, not only by end-to-end runs against MinIO. MinIO must keep passing path-style throughout.
