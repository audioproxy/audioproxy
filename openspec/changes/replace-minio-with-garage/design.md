## Context

The `:minio` suite verifies `AudioProxy.S3` against a store that actually checks signatures (see `openspec/specs/s3-access`: a stub cannot reject a signature). MinIO provided that store in three places: the devcontainer's compose project, the CI `test` job (`docker run`), and `bin/smoke-image` (`docker run` plus `minio/mc` for setup and inspection). All three images are now unpullable.

Probe results against `dxflrs/garage:v2.4.1`, single node, `s3_region = "us-east-1"`, key `GK000000000000000000000000` with an all-zero 64-hex secret:

| Behaviour the suite relies on | Garage |
|---|---|
| `--single-node --default-access-key` boot, health on the admin port | `200` on `:3903/health` about 4 s after start; key may create buckets |
| CreateBucket twice | second call `409 BucketAlreadyOwnedByYou` |
| Missing bucket | `NoSuchBucket` |
| Presigned GET / tampered / unsigned | `200` / `403` / `403` |
| Presigned GET, expired | **`400`** (AWS and MinIO answer `403`) |
| Wrong secret on HEAD | `403` |
| Multipart: `ListParts`, `ListMultipartUploads`, `HEAD ?partNumber=1` | sizes, keys and `PartsCount` as expected |
| Multipart with two 1 KiB parts | **accepted** (AWS and MinIO refuse with `EntityTooSmall`) |
| User metadata, ranged GET | round-trips; `206` |

## Goals / Non-Goals

**Goals:**

- `main` green again, with the store-backed suite still running in CI rather than skipped.
- One store image, pinned by digest, used identically by the devcontainer, CI and the smoke test.
- A store that boots from configuration alone, with no init container and no script.

**Non-Goals:**

- Testing against several stores. `docs/s3-providers.md` already describes pointing the suite at another endpoint by hand; that stays manual.
- Changing any `lib/` behaviour. If a Garage difference seems to call for one, it is a finding for its own change.

## Decisions

**Garage, not a republished MinIO.** Chainguard still publishes a MinIO image, but it is a third party rebuilding a product whose upstream has stopped publishing, which is how this broke in the first place. Garage is published by its own maintainers, and its single-node flags remove the bootstrap step MinIO never needed but most alternatives do. *Considered:* SeaweedFS (heavier, several processes) and RustFS (young). Both are viable fallbacks behind the same helper if Garage ever goes the same way.

**Config file mounted, not baked.** Garage reads `/etc/garage.toml`. One `test/support/garage.toml` is mounted by all three consumers, so region, ports and the replication factor cannot drift between them. The `rpc_secret` in it is a fixed test value, like the signing key material in `SignedRequest`, and says so.

**Region pinned to `us-east-1`** through `s3_region`, so the region every test already signs with does not change. Garage's default region is `garage`, and a SigV4 region mismatch is refused, which would fail every test for a reason unrelated to what each one checks.

**Health from the admin API.** The `/minio/health/live` probe in the helper and in CI becomes `GET :3903/health`. The admin port is published only where the S3 port is (CI's `docker run`); in compose, nothing is published, as before.

**Credentials in `StoreHelper`, once.** `access_key_id/0` and `secret_access_key/0`, stated as fixed test values. The five files that write the pair today reference those instead; `s3_split_store_test.exs` keeps its second, deliberately different identity, which exists to be told apart from this one.

**The expired-URL assertion accepts `400` or `403`**, like the unsigned-request test beside it already accepts `401` or `403`. The claim under test is that the store refuses, so that the signature and not a public bucket granted access; which 4xx a store uses for an expired signature is its own business. Clients follow a redirect to the store directly, so the proxy never maps this status.

**`EntityTooSmall` needs no change.** The single-`PutObject` test asserts on the ETag shape (MD5 vs `-<parts>` digest), not on the store refusing a small multipart upload, so it holds on a store that accepts one. The requirement in `s3-access` still stands, because AWS and R2 enforce it; Garage simply cannot demonstrate it, and did not have to.

**`amazon/aws-cli` for `bin/smoke-image`.** `mc` did three things there: create buckets, upload a fixture, list what the image wrote. `--default-bucket` covers the first bucket only, and the smoke test uses two, so a client is still needed. The AWS CLI is published by AWS and pinned by tag (`2.37.3`).

**The rename lands as its own commit**, after the swap, so the swap is reviewable without a tag rename running through every file.

## Risks / Trade-offs

**A Garage behaviour the probe did not reach.** The probe covered what the suite asserts, found by grepping it, not every request the S3 layer can make. → The full `--include minio` run in the worktree is the real check; any further difference is recorded in the table above with how it was resolved.

**Garage accepts undersized multipart parts**, so the suite can no longer catch a regression where a small variant goes multipart. → The ETag-shape test above catches it regardless of the store, which is why it was written that way.

**A second image to keep pullable in the smoke test.** → Pinned by tag and published by AWS; losing it fails loudly at `docker pull`, not silently.

**Worktrees in flight have a stale compose project.** → Rebasing and `devcontainer up` recreates it; noted in `docs/development.md`.
