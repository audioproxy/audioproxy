## 1. The error row

- [ ] 1.1 `ErrorJSON`: add the `:upstream_unavailable` row (502, `no-store`) and its `class/1` clause; unit-test the body shape alongside the existing rows
- [ ] 1.2 `docs/audio-proxy-api-v1.md` §5 error table and edge-cache discipline; README error table

## 2. The backend

- [ ] 2.1 `Source.S3.stat/1` via `AudioProxy.S3.head/2` — size and ETag onto the seam's `stat()`
- [ ] 2.2 `Source.S3.ffmpeg_input/1` via `AudioProxy.S3.presign_get/3` with `AP_PRESIGN_TTL`; single argv element
- [ ] 2.3 Classify every `AudioProxy.S3.error()` shape at the seam, one clause each, no catch-all: `:not_found`/`:access_denied`/`{:http, 4xx, _}` → blind 404, `:not_configured` → 500, `{:transport, _}`/`{:http, 5xx, _}` → 502
- [ ] 2.4 Drop `:no_backend` from `Source.S3`'s reason list, its `message/1` clause and the moduledoc's "Status" section; delete the test that pinned the gap

## 3. Tests

- [ ] 3.1 Unit: each error shape maps to its status, with `access_denied` proved byte-identical to the missing-object 404
- [ ] 3.2 Integration against MinIO (the harness `add-s3-client` established): render an `s3://` source end to end, `/info` an `s3://` source, 413 on an oversized object, 502 on an injected 5xx
- [ ] 3.3 The seam's claim, asserted directly: the render and info flows are unchanged by this slice — no diff outside `source/s3.ex` and `error_json.ex`

## 4. Docs

- [ ] 4.1 README: `s3://` sources work; drop the "next slice" hedging in Sources and the roadmap
- [ ] 4.2 Note that `AP_PRESIGN_TTL` bounds the URL, not the read: ffmpeg opens within the TTL and the connection outlives it

## Release-gate coverage (added 2026-08-05, from the v0.3.0 post-mortem)

- [ ] R.1 Extend the container smoke suite: an `s3://` source rendered end-to-end through the HTTP endpoint against MinIO — the release gate could not see S3 at all, which is how v0.3.0's notes shipped claims no check demonstrated
