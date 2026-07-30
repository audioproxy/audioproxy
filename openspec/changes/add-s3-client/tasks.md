## 1. SigV4 core

- [ ] 1.1 `AudioProxy.S3.SigV4`: canonical request, string-to-sign, signing key derivation, presigned-URL query construction
- [ ] 1.2 Unit tests: AWS SigV4 known-answer vectors (fixed credentials/timestamp → expected signature), key-escaping cases (space, `+`, unicode, `/` in key)

## 2. Client operations

- [ ] 2.1 `S3` behaviour + `S3.Client` (`:httpc`): `presign_get/3`, `head/2`, `put_stream/3` (multipart, 8 MiB parts, abort on error, single-part fast path)
- [ ] 2.2 Endpoint/addressing: virtual-hosted for AWS, path-style with `AP_S3_ENDPOINT`; region + credentials from env; config additions with boot validation
- [ ] 2.3 Unit tests against a Bandit-based fake S3 (records requests, serves canned responses): HEAD found/missing/500, multipart happy path, mid-stream abort issues AbortMultipartUpload

## 3. Integration

- [ ] 3.1 MinIO service in the devcontainer; `@tag :integration` suite: presigned GET fetchable, expiry rejected, HEAD, multipart round-trip byte-equality
- [ ] 3.2 Wire `:integration` tag exclusion into default `mix test`, inclusion in CI job with MinIO

## 4. Docs

- [ ] 4.1 Update README + CLAUDE.md open questions: decision recorded (hand-rolled SigV4), AWS env vars, `AP_S3_ENDPOINT`, IAM-role limitation
