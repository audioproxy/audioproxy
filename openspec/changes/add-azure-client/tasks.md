# Tasks

## 1. Signing

- [ ] 1.1 Private SAS module: string-to-sign for the pinned `x-ms-version`, HMAC-SHA256 over the base64-decoded account key, query-parameter assembly; permissions/expiry/resource as arguments
- [ ] 1.2 Known-answer vectors for the pinned version (hand-checked against Azure's documented example or a captured live signature)
- [ ] 1.3 URL assembly for both endpoint shapes: account-in-host (default) and account-in-path (`AP_AZURE_ENDPOINT`); canonicalized resource identical in both

## 2. Facade

- [ ] 2.1 `AudioProxy.Azure.head/2` — Get Blob Properties via short-lived `r` SAS; size/ETag/content type/cache control/metadata extraction
- [ ] 2.2 `presign_get/3` — SAS GET URL with caller TTL (default from `presign_ttl`), the value handed to ffmpeg and to HIT redirects later
- [ ] 2.3 `put_stream/4` — Put Block per chunk group (fixed-length base64 counter IDs), Put Block List commit with blob-property headers and `x-ms-meta-*`; block-count guard
- [ ] 2.4 `get_stream/3` (ranged GET) and `delete/2`
- [ ] 2.5 Error mapping: 404 → `:not_found`, 403 → `:access_denied`, transport errors, `{:http, status, body}` rest; `configured?/0`

## 3. Config

- [ ] 3.1 `AudioProxy.Config`: `AP_AZURE_ACCOUNT`/`AP_AZURE_KEY` both-or-neither (boot abort naming the gap), optional `AP_AZURE_ENDPOINT`

## 4. Tests

- [ ] 4.1 SAS KAT vectors; property test for block ID shape (fixed length, ordered, unique)
- [ ] 4.2 Azurite in CI and the devcontainer compose, behind `@tag :azurite`; full facade round-trip: put_stream → head → get_stream (full + ranged) → delete
- [ ] 4.3 Presigned GET against Azurite: 200 full read and 206 Range read with no auth header
- [ ] 4.4 Error mapping against Azurite: missing blob, wrong key (403), metadata round-trip
- [ ] 4.5 Boot validation: partial group aborts naming the variable

## 5. Docs

- [ ] 5.1 README configuration table: `AP_AZURE_*` rows (marked "no consumer until the Azure source/store slices land" if this merges first)
- [ ] 5.2 `docs/development.md`: Azurite in the suite, its tag, how to run it locally
