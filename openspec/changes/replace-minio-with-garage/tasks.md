## 1. Store configuration

- [x] 1.1 Add `test/support/garage.toml` (single node, sqlite, `s3_region = "us-east-1"`, S3 on 3900, admin on 3903), its `rpc_secret` marked as a fixed test value
- [x] 1.2 Replace the `minio` compose service with one running `dxflrs/garage:v2.4.1@sha256:9c96caa2…` with `--single-node --default-access-key`, the config mounted, `/var/lib/garage` on tmpfs, and `/garage status` as the healthcheck (the image has no shell); update `runServices` in `devcontainer.json`
- [x] 1.3 Replace CI's `Start MinIO` step with the same image and config via `docker run`, polling `:3903/health`

## 2. Test support

- [x] 2.1 Point `MinioHelper` at Garage: endpoint default, health probe path, and `access_key_id/0` / `secret_access_key/0` as the credentials' one home; the private `ensure_bucket!`/`ensure_reachable!` copies in `s3_test.exs` and `source/s3_backend_test.exs` now call it, and the probe accepts any HTTP answer so it stays provider-neutral
- [x] 2.2 Replace the literal credential pair in `s3_test.exs`, `source/s3_backend_test.exs`, `variant_store/s3_test.exs` and `s3_split_store_test.exs` with the helper's, keeping the split-store test's second identity distinct
- [x] 2.3 Accept `400` or `403` for the expired presigned URL in `s3_test.exs`, with the reason in the assertion message
- [x] 2.4 Run `mix test --include integration --include minio` in the devcontainer; record any further Garage difference in `design.md` with how it was resolved (none: 98 store tests, 1267 overall, green on the first run)

## 3. Image smoke test

- [ ] 3.1 Switch `bin/smoke-image` to the Garage image and config, and replace `mc` with `amazon/aws-cli:2.37.3` for bucket creation, the fixture upload and the listing
- [ ] 3.2 Run `bin/smoke-image` locally against a freshly built image

## 4. Rename (own commit)

- [x] 4.0 Rewrite this change's comments in ASD-STE100 Simplified Technical English, per the rule added to `CLAUDE.md` in this change

- [x] 4.1 `:minio` → `:garage` in `test_helper.exs` and every tagged file; `AP_TEST_MINIO_ENDPOINT` → `AP_TEST_GARAGE_ENDPOINT` in the helper, compose and CI; `AudioProxy.MinioHelper` → `AudioProxy.GarageHelper`; compose service `minio` → `garage`
- [x] 4.2 Check `grep -rni minio` outside `deps`, `_build` and archived changes returns only operator-facing mentions (example endpoints, `docs/s3-providers.md` provider notes)

## 5. Documentation

- [ ] 5.1 `docs/development.md`: the store section (compose service, manual `docker run`, credentials, tag), the CI job table, and a note that in-flight worktrees need `devcontainer up` after rebasing
- [ ] 5.2 `docs/s3-providers.md`: the store the suite tests against, and the Garage differences (expired-URL status, no minimum part size) as a provider note
- [ ] 5.3 `CLAUDE.md`: the MinIO mentions in the test-support section (`CapturingStore` rules)
- [ ] 5.4 Update the `add-gcs-source-backend` and `add-gcs-variant-store` tasks that name MinIO and `@tag :minio`

## 6. Verify

- [ ] 6.1 Push and confirm the CI `test` job and the image verification jobs are green
