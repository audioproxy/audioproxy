# Add GCS Source Backend

## Why

Google Cloud Storage speaks the S3 XML API natively — interoperability mode at `https://storage.googleapis.com` with HMAC keys, SigV4 signing and presigning included — so the proxy can already read GCS today by pointing `AP_S3_ENDPOINT` at it. But that repurposes the *global* S3 configuration: a deployment cannot have AWS (or R2, or MinIO) sources and GCS sources at the same time, and nothing in the docs says the interop path exists at all. A first-class `gcs://` scheme with its own credential group makes GCS a peer of `s3://` instead of a configuration trick, and costs almost nothing: the client, the signing, the multipart machinery are all the existing `ExAws` stack under a different profile.

## What Changes

- A `gcs://bucket/key` source scheme, `AudioProxy.Source.Gcs`, implementing the five `Source.Type` callbacks. `stat/1` and `ffmpeg_input/1` delegate to `AudioProxy.S3.head/2` and `presign_get/3` under a **`:gcs` client profile** — same facade, different signing identity and endpoint.
- A group-atomic `AP_GCS_*` config group: `AP_GCS_KEY_ID` + `AP_GCS_SECRET` (GCS HMAC interoperability keys, both-or-neither), optional `AP_GCS_ENDPOINT` (default `https://storage.googleapis.com`; overridable for an emulator or private Google endpoint). Addressing defaults to path-style. A `gcs://` source with no group set is `:not_configured` → 500, mirroring `s3://` without credentials.
- Bucket allowlisting via the existing `AP_SOURCE_ALLOWLIST`, same semantics as `s3://` buckets.
- Docs: `docs/s3-providers.md` gains a GCS section covering **both** routes — the zero-code interop path (`AP_S3_ENDPOINT=https://storage.googleapis.com`, for GCS-only deployments) and the `gcs://` scheme (for mixed ones). API doc §1 scheme table, README sources section, `llms-full.txt` scheme list.

## Non-goals

- **Native Google auth** (service-account JSON, OAuth token exchange, workload identity). HMAC keys are created per service account and are the documented interop mechanism; orgs that prohibit them need an OAuth/RSA-signing implementation that is its own change — deferred by name as `add-gcs-native-auth`, to be proposed if a deployment ever requires it.
- A `AP_VARIANT_GCS_*` override group (GCS store with *different* GCS credentials than GCS sources). Cross-provider splits are already expressible because schemes are separate; a within-provider split follows `split-s3-credentials`' pattern later if demanded.

## Sequencing

Rides on `split-s3-credentials`' profile parameterization of the S3 client (its task 1.2). Whichever lands first introduces the parameterization; the other inherits it and shrinks. The GCS profile is a third profile, not a special case.

## Capabilities

### New Capabilities

<!-- none -->

### Modified Capabilities

- `remote-sources`: a third remote scheme, `gcs://`, with bucket/key semantics identical to `s3://`.
- `s3-access`: the client supports a `:gcs` profile (own credentials, fixed default endpoint, path-style default).

## Impact

- New: `AudioProxy.Source.Gcs` (thin — parsing/limits/canonical mirror `Source.S3`, storage seam delegates under the profile).
- Modified: `AudioProxy.Config` (the `AP_GCS_*` group), the resolver dispatch table, `AudioProxy.S3` profile plumbing (or inherited from `split-s3-credentials`), README, API doc, `llms-full.txt`, `docs/s3-providers.md`.
- CI tests point `AP_GCS_ENDPOINT` at the suite's existing S3 fake/MinIO: the delta under test is profile threading and the scheme, not SigV4, which is already covered. The claim that the real interop endpoint behaves is verified by a manual smoke task against live GCS, recorded in the PR.
- Estimated well under the slice budget (~200 LOC).
- Position: parked with trigger — first deployment wanting GCS sources (or the imgproxy-parity argument maturing). The `docs/s3-providers.md` interop section can be pulled forward as a free docs commit at any time.
