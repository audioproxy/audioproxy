## Context

The client already assembles its `ex_aws` configuration in one place; this change makes that assembly a function of a profile and builds two. The store backend takes the store profile; everything else keeps the source profile. Named after `split-retention-cap` deliberately: same failure pattern (one knob, two jobs), same upgrade posture (new knob defaults to the old one's value).

## Goals / Non-Goals

**Goals:**
- Cross-provider and split-principal deployments expressible; unset = exactly today, pinned.

**Non-Goals:**
- Per-source-bucket credentials (the allowlist names many buckets under one principal; per-bucket identity is a different, unrequested feature).
- Credential providers beyond env (IMDS/STS remains the recorded limitation for both profiles).
- A third profile for anything else; two jobs, two profiles, done.

## Decisions

- **Fallback per variable, atomicity per credential group**: endpoint, addressing and CA bundle degrade independently (each is meaningful alone); identity does not (a key from one principal with a secret from another is never a deployment intent). Boot names exactly what is missing.
- **Derivation rules run after fallback, per side**: addressing's "virtual for AWS, path for custom endpoints" default reads the side's own effective endpoint — the least-surprise reading, and the one that makes an R2 store behind an AWS source setup work unconfigured.
- **Presign always store-side** for store objects: the signature embeds host and credentials, so using the wrong profile is not a degraded mode, it is a broken URL. The parity suite gains a split-profile leg.
- **Test topology**: one MinIO with two users (split principals) plus the existing fake S3 as the second endpoint (cross-provider) — no second MinIO service; the fake already speaks enough S3 for HEAD/PUT assertions.

## Risks / Trade-offs

- [Config surface grows by seven variables] → all optional, all documented in one table row group, and the no-override path is the tested default; the surface is opt-in complexity.
- [Two profiles double the addressing/endpoint edge cases] → the addressing suite is parameterized over profiles rather than duplicated.
