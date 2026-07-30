## Why

The source segment (API doc §1) must be parsed and authorized before anything can be fetched: `plain/s3://…`, `plain/https-url`, and `enc/base64url` forms, gated by `AP_SOURCE_ALLOWLIST`. Pure string work plus policy — independently buildable and testable.

## What Changes

- Parse the trailing source segments into a typed source: `{:s3, bucket, key}` or `{:http, url}`.
- Support `plain/` (URL-escaped) and `enc/` (base64url of the plain form) encodings.
- Enforce the allowlist (bucket/host patterns, comma-separated) → authorization error (maps to 404, no oracle).
- Canonical source string for cache-key derivation (both encodings of the same source yield the same key).

## Capabilities

### New Capabilities

- `source-resolution`: Source-segment grammar, decoding, allowlist policy, and canonical source identity.

### Modified Capabilities

<!-- none -->

## Impact

- New: `lib/audio_proxy/source.ex`.
- Depends on: `init-project-scaffold` (config).
- Blocks: `add-render-endpoint`, `add-s3-client` (consumes `{:s3, bucket, key}`), `add-info-endpoint`.
