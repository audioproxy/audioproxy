## 1. Source form & confinement

- [ ] 1.1 `local://` parsing in `AudioProxy.Source` (plain + enc), typed local source, canonical `local://relative/path` identity
- [ ] 1.2 Config: `AP_LOCAL_ROOT` (optional, validated as an existing directory at boot when set)
- [ ] 1.3 Confinement: decode-once → `Path.safe_relative/2` → symlink/realpath prefix assertion; regular-file check; every failure → `{:error, :not_allowed}` (404)
- [ ] 1.4 Tests: parse/encoding-equivalence scenarios; traversal corpus (dot-dot, encoded, absolute, null byte, symlink escape); property — accepted ⇒ canonical path has root prefix; unset-root rejection

## 2. Storage seam

- [ ] 2.1 `Source.Store.stat/1` (local: `File.stat` → size + etag material; missing/non-regular → not_found) and `Source.Store.ffmpeg_input/1` (local: absolute resolved path)
- [ ] 2.2 Tests: stat scenarios (missing, oversized handled by caller, directory/FIFO), stub backend proving the render-flow contract is seam-only

## 3. Docs

- [ ] 3.1 Amend `docs/audio-proxy-api-v1.md` §1: `local://{path}` source form, root config, confinement policy
- [ ] 3.2 Update README: local source usage (the zero-S3 quickstart becomes the default dev experience), `AP_LOCAL_ROOT`

Note: the cross-slice artifact amendments this reordering required (render-endpoint,
docker-release, audio-only-policy, s3-client, info-endpoint) were applied at proposal
time, in the same commit as this change.
