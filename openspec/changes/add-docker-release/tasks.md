## 1. Release & image

- [x] 1.1 `mix release` config + `config/runtime.exs` (all `AP_*` reads moved/validated there, shared with dev boot path)
- [x] 1.2 Multi-stage `Dockerfile` (hexpm/elixir build → alpine runtime: ffmpeg, tini, non-root user, HEALTHCHECK), `.dockerignore`, OCI provenance labels
- [x] 1.3 `VERSIONS.md`: alpine/elixir/OTP/ffmpeg pins mirroring `.tool-versions`

## 2. Verification

- [x] 2.1 Ruby smoke script: build → boot with a **read-only** mounted fixture volume (`AP_LOCAL_ROOT=/fixtures`, mounted `:ro` — a writable root is the precondition for the hardlink and TOCTOU exposures the local-source review identified, so the smoke test should demonstrate the posture the README tells operators to use) → health → insecure end-to-end render from a local source → duration assertion → SIGTERM clean-exit + no-orphan check (final process table)
- [x] 2.2 Config tests in-container: env override effective; malformed `AP_KEY` exits nonzero with message
- [x] 2.3 Extend `.github/workflows/ci.yml`: image-build + smoke jobs (`needs: test`), `--only ffmpeg` integration against the image's ffmpeg, ffmpeg major-version assertion
- [x] 2.4 Smoke: signed URL containing percent-escapes over h2c (`curl --http2-prior-knowledge`) — Bandit's HTTP/2 path builds `request_path` separately from HTTP/1.1 (which the `:integration` tests cover), so the signed-escapes assertion must hold there too

## 3. Publishing & versioning

- [x] 3.1 Publish job in `ci.yml` (`needs: smoke`): GHCR login via `GITHUB_TOKEN`; on `v*` tags push `:X.Y.Z`/`:X.Y`/`:latest`, on `main` push `:edge` + `:sha-<12>`
- [x] 3.2 Release assertion: `mix.exs` version == git tag, or the publish job fails
- [ ] 3.3 Verify (scratch pre-release tag): package appears on GHCR linked to the repo, OCI labels present (`docker inspect`), `:sha-*` pullable and boots
- [ ] 3.4 Cut `v0.1.0` once the MVP smoke suite is green on main

## 4. Docs

- [x] 4.1 Update README: docker pull/run quickstart (local-source mode, zero S3 config; recommend `:X.Y.Z` or `:sha-*`, not `:latest`), env reference
- [x] 4.2 `docs/development.md`: release procedure (tag → publish), versioning policy (what bumps what — incl. "pin bumps cut a patch release" and "cache-key changes are major"), upgrade procedure for pinned toolchain versions
