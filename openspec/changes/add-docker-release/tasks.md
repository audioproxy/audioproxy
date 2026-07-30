## 1. Release & image

- [ ] 1.1 `mix release` config + `config/runtime.exs` (all `AP_*` reads moved/validated there, shared with dev boot path)
- [ ] 1.2 Multi-stage `Dockerfile` (hexpm/elixir build → alpine runtime: ffmpeg, tini, non-root user, HEALTHCHECK), `.dockerignore`
- [ ] 1.3 `VERSIONS.md`: alpine/elixir/OTP/ffmpeg pins mirroring `.tool-versions`

## 2. Verification

- [ ] 2.1 Ruby smoke script: build → boot with fake S3 → health → insecure end-to-end render → duration assertion → SIGTERM clean-exit + no-orphan check (final process table)
- [ ] 2.2 Config tests in-container: env override effective; malformed `AP_KEY` exits nonzero with message
- [ ] 2.3 Extend `.github/workflows/ci.yml`: image-build + smoke jobs (`needs: test`), `--only ffmpeg` integration against the image's ffmpeg, ffmpeg major-version assertion

## 3. Docs

- [ ] 3.1 Update README: docker build/run quickstart, env reference, upgrade procedure for pinned versions
