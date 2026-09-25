## Why

The S3-compatible store this project tests against can no longer be pulled. `minio/minio:RELEASE.2025-04-22T22-12-26Z` answers `pull access denied … repository does not exist`, the same tag on `quay.io/minio/minio` is gone, and so is `minio/mc`. Three things depend on those images:

- **CI on `main` is red.** The `test` job's `Start MinIO` step fails in about 30 seconds; the last two runs (the `add-peaks-bit-depth` proposal push and a dependabot PR) both died there. Nothing can merge green until this lands.
- **No new devcontainer can start.** Compose builds `app`, then fails on `minio`, and `app` waits on its health. Every `wt switch --create` is currently broken.
- **`bin/smoke-image` cannot run.** It boots MinIO for its S3 checks and uses `mc` to create buckets, upload a fixture and list what the image wrote.

The `:minio` suite exists because signing is only verified by a store that can reject a signature. Replacing the store keeps that property; dropping the suite would not.

[Garage](https://garagehq.deuxfleurs.fr/) is a self-hosted S3-compatible store published on Docker Hub as `dxflrs/garage`. Since 2.x it boots as a single node with a preset key from environment variables (`--single-node --default-access-key`), so it needs no bootstrap script. Probed against 2.4.1 before writing this: SigV4 header and presigned auth, tampered and unsigned refusals, `BucketAlreadyOwnedByYou`, `NoSuchBucket`, multipart with `ListParts` / `ListMultipartUploads`, `HEAD ?partNumber=1` reporting `PartsCount`, user metadata, and ranged `206`s all behave as the suite expects.

## What Changes

- Replace MinIO with `dxflrs/garage:v2.4.1`, pinned by digest, in `.devcontainer/docker-compose.yml`, the CI `test` job and `bin/smoke-image`, so the three levels test against the same store.
- Replace `minio/mc` in `bin/smoke-image` with `amazon/aws-cli`, pinned, for the fixture upload and the listing.
- Give the suite's store credentials one home in the support layer. The fixed `minioadmin` pair is written out in five test files today, and Garage's key format (`GK` + 24 hex, a 64-hex secret) means every copy changes anyway.
- Loosen the one assertion that encodes a MinIO-specific status: an expired presigned URL is refused with `400` by Garage and `403` by AWS and MinIO. The requirement is that the store refuses, not which 4xx it picks.
- Rename what names the product rather than the role: the `:minio` tag becomes `:s3_store`, `AP_TEST_MINIO_ENDPOINT` becomes `AP_TEST_S3_ENDPOINT`, `AudioProxy.MinioHelper` becomes `AudioProxy.StoreHelper`, and the compose service becomes `s3`. Doing it now keeps the next store swap from being a rename as well.
- Update `docs/development.md`, `docs/s3-providers.md` and the MinIO mentions in `CLAUDE.md`.

## Capabilities

### New Capabilities

None.

### Modified Capabilities

- `ci-pipeline`: the store-backed suite gets a requirement of its own (today it is implied only by the purpose text), including that CI, the devcontainer and the image smoke test use one pinned store image.
- `test-support`: the store credentials join the key material as something defined once in the support layer.

## Impact

**Code.** Test support and the six `:minio`-tagged files; `bin/smoke-image`; no `lib/` behaviour changes. A few `lib/` comments use `http://minio:9000` as an example endpoint; those stay, since MinIO remains a store operators run.

**CI and dev.** `.github/workflows/ci.yml`, `.devcontainer/docker-compose.yml`, `.devcontainer/devcontainer.json`. Existing worktrees need `devcontainer up` again after rebasing, since their compose project gains a service and loses one.

**Docs.** `docs/development.md`, `docs/s3-providers.md` (which says MinIO is the only store tested against), `CLAUDE.md`. Unchanged: the API contract and `llms-full.txt`, because `AP_TEST_*` is not part of the `AP_` configuration surface.

**Sequencing.** Lands before `add-peaks-bit-depth` and anything else in flight, which rebase onto it.
