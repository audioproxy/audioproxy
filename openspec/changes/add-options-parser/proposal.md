## Why

The options string *is* the API (doc §3): every variant is fully described by its processing options, which double as the cache key. Parsing, validation, and normalization must exist — and be provably deterministic — before the command builder, cache, or endpoint can be built.

## What Changes

- Parse the ordered `/`-separated `key:value` options segments into a typed options struct.
- Validate per §3: known keys, value domains, conflicts (`br` xor `q`, `bd` lossless-only, peaks-only keys with `f:peaks`, …) → structured errors that map to 422.
- Normalize: canonical ordering, canonical value rendering (e.g., `t:30` ≡ `t:30.0`? — decided: canonical decimal form), defaults applied (`f:mp3`).
- Derive the cache key from the normalized options + source.
- Property tests guaranteeing parse → normalize is idempotent and order-insensitive.

## Capabilities

### New Capabilities

- `processing-options`: Options-string grammar, validation rules, normalization, and cache-key derivation.

### Modified Capabilities

<!-- none -->

## Impact

- New: `lib/audio_proxy/options.ex` (+ per-option validation), `lib/audio_proxy/cache_key.ex`.
- Depends on: `init-project-scaffold`.
- Blocks: `add-ffmpeg-command-builder`, `add-render-endpoint`, `add-variant-cache`, `add-peaks-format`.
