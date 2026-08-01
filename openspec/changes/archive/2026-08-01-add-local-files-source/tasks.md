## 1. Source form & confinement

- [x] 1.1 `AudioProxy.Source.Local` implementing `Source.Type`: scheme/tag, `parse/1` of the decoded body, canonical `local://relative/path` identity, `authorize/1` (root confinement, not an allowlist); register it in the resolver's dispatch table
- [x] 1.2 Config: `AP_LOCAL_ROOT` (optional, validated as an existing directory at boot when set)
- [x] 1.3 Confinement: decode-once → `Path.safe_relative/2` → symlink/realpath prefix assertion; regular-file check; every failure → `{:error, :not_allowed}` (404)
- [x] 1.4 Tests: parse/encoding-equivalence scenarios; traversal corpus (dot-dot, encoded, absolute, null byte, symlink escape); property — accepted ⇒ canonical path has root prefix; unset-root rejection

## 2. Storage seam

- [x] 2.1 Implement the seam callbacks for local sources: `stat/1` (`File.stat` → size + etag material; missing/non-regular → not_found) and `ffmpeg_input/1` (absolute resolved path)
- [x] 2.2 Tests: stat scenarios (missing, oversized handled by caller, directory/FIFO), and a stub type proving the render-flow contract is seam-only

## 3. Docs

- [x] 3.1 Amend `docs/audio-proxy-api-v1.md` §1: `local://{path}` source form, root config, confinement policy
- [x] 3.2 Update README: local source usage (the zero-S3 quickstart becomes the default dev experience), `AP_LOCAL_ROOT`

Note: the cross-slice artifact amendments this reordering required (render-endpoint,
docker-release, audio-only-policy, s3-client, info-endpoint) were applied at proposal
time, in the same commit as this change.
