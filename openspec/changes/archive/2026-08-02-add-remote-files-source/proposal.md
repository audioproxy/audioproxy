## Why

`add-source-resolver` was carrying three things at once: the encoding layer every source shares, and the `s3://` and `https://` source forms with their allowlist. Splitting the two out leaves the resolver source-type agnostic — a decode-once pipeline plus a dispatch table — and puts the remote forms where their policy lives. Neither form has an MVP consumer (the MVP renders from disk via `add-local-files-source`; `add-s3-client` is post-MVP), so this slice sequences with them rather than ahead of them.

## What Changes

- New source forms `s3://{bucket}/{key}` and `https://{host}/{path}`, both encodings, implementing the `AudioProxy.Source.Type` behaviour from `add-source-resolver`.
- `AP_SOURCE_ALLOWLIST` and its pattern matcher: exact, trailing-`*` prefix glob for buckets, leading-`*.` label-anchored suffix glob for hosts. Unset = HTTP refused, S3 accepted.
- Canonical identity for both forms, including HTTPS URL normalization (case, trailing root dot, IP literal spelling, default port, empty path/query, fragment).
- `http://`, userinfo-bearing URLs, and IDN-ambiguous hosts refused at the grammar.
- Both forms ship with "no backend" storage stubs pinned by tests — the HTTPS backend follows in `add-https-source-backend`, the S3 backend in `add-s3-client`.
- **BREAKING** relative to what `add-source-resolver` proposed before this split: that slice no longer knows any source form, so nothing renders from S3 or HTTPS until this change lands.

## Capabilities

### New Capabilities

- `remote-sources`: The `s3://` and `https://` source forms, their canonical identity, and the `AP_SOURCE_ALLOWLIST` policy that gates them.

### Modified Capabilities

<!-- none — `source-resolution` defines the type contract; this registers two types behind it -->

## Impact

- New: `lib/audio_proxy/source/s3.ex`, `lib/audio_proxy/source/https.ex`, allowlist matcher, HTTPS store backend.
- Config: `AP_SOURCE_ALLOWLIST` gains its only consumer (it is parsed today and used by nothing).
- Depends on: `add-source-resolver` (the `Source.Type` behaviour and dispatch table it registers into).
- Blocks: `add-https-source-backend` (HTTPS store backend) and `add-s3-client` (S3 store backend) — both implement the seam for forms defined here.
- Sequencing: post-MVP, alongside or before `add-s3-client`. The MVP chain does not include it.
