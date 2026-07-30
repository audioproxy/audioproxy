## 1. Parsing

- [ ] 1.1 `AudioProxy.Source.parse/1`: split `plain/` vs `enc/`, base64url decode, URL-unescape, yield `{:s3, bucket, key} | {:http, url}`
- [ ] 1.2 Structured errors: unknown scheme, missing key, undecodable enc, non-https HTTP URL
- [ ] 1.3 `Source.canonical/1` → canonical string for cache-key input

## 2. Allowlist

- [ ] 2.1 Pattern matcher: exact + trailing-`*` glob over bucket/host; unset-allowlist policy (S3 yes, HTTP no)
- [ ] 2.2 `Source.authorize/2` returning `:ok | {:error, :not_allowed}`

## 3. Tests

- [ ] 3.1 Unit: each scenario from the spec (both encodings, escaping, malformed inputs, allowlist hit/miss/wildcard, unset policy)
- [ ] 3.2 Property: `parse(enc(plain_form)) == parse(plain_form)` for generated buckets/keys/URLs incl. reserved characters
- [ ] 3.3 Property: canonical string is stable across encoding variants and never contains percent-escapes

## 4. Docs

- [ ] 4.1 Update README: source forms, allowlist syntax and default policy
