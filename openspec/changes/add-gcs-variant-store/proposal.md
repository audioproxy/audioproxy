# Add GCS Variant Store

## Why

`add-gcs-source-backend` makes GCS readable; this makes it the write-back target, so a deployment living entirely on Google infrastructure — sources in one GCS bucket, rendered variants cached in another — needs no AWS-shaped configuration at all. The mechanism is the same bet as the source side: GCS's XML API is S3-compatible through multipart uploads (`InitiateMultipartUpload`/`UploadPart`/`Complete`, GA on GCS), so `VariantStore.S3`'s machinery — single-PUT fast path, 5 MiB part grouping, metadata round-trip, presigned HIT redirect — runs unchanged under the `:gcs` profile. The slice is store-URL plumbing, a boot probe, and the verification that the compatibility claim holds, not new storage code.

## What Changes

- `AP_VARIANT_STORE=gcs://bucket` is accepted; the store backend is `VariantStore.S3` parameterized by the `:gcs` client profile (or a thin `VariantStore.Gcs` wrapper if the parameterization reads worse than a module).
- The boot writability probe runs under the GCS profile; a `gcs://` store with no `AP_GCS_*` group configured aborts boot.
- HIT serving works in both modes: 302 to a presigned GCS URL (redirect, the default) and proxy mode (`get_stream` under the profile).
- Docs: README variant-store section and configuration table, `docs/s3-providers.md` cross-provider example gains a GCS variant (sources on AWS, variants on GCS).

## Non-goals

- A `AP_VARIANT_GCS_*` credential override (GCS store under *different* GCS credentials than GCS sources) — follows `split-s3-credentials`' pattern later if a deployment demands it.
- Retention/eviction — `split-retention-cap` owns that story regardless of backend.

## Capabilities

### New Capabilities

<!-- none -->

### Modified Capabilities

- `variant-cache`: a `gcs://bucket` store URL, backed by the S3 store machinery under the GCS client profile.

## Impact

- Modified: `AudioProxy.Config` (store-URL parsing accepts `gcs://`), `VariantStore.S3` (profile threading), boot probe, README, `docs/s3-providers.md`.
- Hard dependency: `add-gcs-source-backend` (the `:gcs` profile and `AP_GCS_*` group exist there).
- The S3-compat multipart claim is the risk this slice retires: CI pins the mechanics against the suite's S3 fake/MinIO via `AP_GCS_ENDPOINT`; a manual smoke against live GCS (MISS → multipart write-back → HIT redirect, plus a variant large enough to cross the multipart threshold) is a named task recorded in the PR, per the release-notes-name-their-checks rule.
- Estimated ~150 LOC.
- Position: immediately after `add-gcs-source-backend`, same trigger.
