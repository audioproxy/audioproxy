## Why

One `AWS_*` credential group and one `AP_S3_ENDPOINT` serve two unrelated jobs: fetching sources and running the variant store. Two ordinary deployment shapes are therefore inexpressible — cross-provider (sources on Cloudflare R2, variants on AWS), and split principals (a read-only credential for source buckets, a writing one for the store). This is the `split-retention-cap` pattern again: one knob quietly doing two jobs, discovered when a deployment wants to say something the vocabulary cannot. Within one provider, IAM policy scoping on the single credential covers the security half today; across providers or principals, nothing does.

## What Changes

- An `AP_VARIANT_S3_*` override group for the variant store: `ENDPOINT`, `ADDRESSING`, `CA_BUNDLE`, and the credential triple (`ACCESS_KEY_ID`, `SECRET_ACCESS_KEY`, `REGION`, plus `SESSION_TOKEN`). Every unset override falls back to the shared value, so an existing deployment upgrades to byte-identical behavior and the split is opt-in.
- **Credentials are group-atomic**: set one of the variant credential triple and you must set them all — a store half-borrowing the source identity is a misconfiguration answered at boot, not a fallback.
- Addressing keeps its derivation rule per side: unset `AP_VARIANT_S3_ADDRESSING` derives from whether the *variant* endpoint is custom, exactly as the shared var derives from the shared endpoint.
- Presigned HIT URLs (redirect mode) sign against the store-side configuration — the host is inside the signature, so this is correctness, not preference.
- Boot validation extends: the store's writability probe runs under the store's own configuration.

## Capabilities

### New Capabilities

<!-- none -->

### Modified Capabilities

- `s3-access`: the client supports two configuration profiles (source-side and store-side), the second defaulting entirely to the first.
- `variant-cache`: an `s3://` store may carry its own endpoint, addressing, and credentials.

## Impact

- Modified: `AudioProxy.Config` (override group + atomicity validation), the S3 client's config assembly, `VariantStore.S3` (uses the store profile), README configuration table, `docs/s3-providers.md` (a cross-provider example).
- Behavior unchanged on upgrade by construction: no overrides set means one profile, identical to today — pinned by a test.
- Position: on demand; trigger = the first deployment needing cross-provider caching or split principals. Proposed now so the sales answer is "designed, small" rather than "unplanned".
