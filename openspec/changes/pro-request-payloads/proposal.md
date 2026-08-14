# PRO: Signed Request Payloads

## Why

Three PRO features need to say more than flat `key:value` options can: `pro-warm-endpoint` (a list of variants), `pro-audio-mix` (a list of tracks with per-track settings), `pro-audio-stitch` (an ordered list of sources). Warm defined its own base64url payload inline; with three consumers that definition graduates to a foundation change, so the envelope, its bounds, and its cache-key rules are specified once and every consumer inherits them. PRO scope, `pro-` prefixed for extraction; no OSS surface changes.

## What Changes

- **The envelope**: a path segment `{key}:{base64url(JSON)}` (unpadded), covered by the URL signature like any other path bytes. Consumers define the JSON schema; this change defines everything schema-independent:
  - **Canonicalization**: before hashing into a cache key, the payload is parsed and re-serialized canonically (sorted object keys, normalized numbers, no insignificant whitespace); array order is significant. Two spellings of the same payload are one cache key - the round-trip rule, extended to payloads.
  - **Bounds**: decoded size capped (default 8 KiB), array lengths capped per consumer, parse errors are the invalid-option error, never a crash.
  - **Cache-key participation is per consumer**: a mix payload is variant-defining (in the key); a warm payload is a request instruction (never cached). The class distinction mirrors `add-expiring-urls`' variant/request option split.
- `pro-warm-endpoint` is amended to build on this envelope instead of defining its own.

## Capabilities

### New Capabilities
- `pro-request-payloads`: the signed payload envelope - encoding, canonicalization, bounds, error mapping, cache-key class rules.

### Modified Capabilities
<!-- none -->

## Impact

- New (PRO tree): payload codec module + property tests (canonicalization round-trip, bound enforcement, malformed-input fuzzing).
- Amended: `pro-warm-endpoint` (consumes the envelope).
- Blocks: `pro-audio-mix`, `pro-audio-stitch`. Deliberately small (~150 LOC); it exists to be finished first.
