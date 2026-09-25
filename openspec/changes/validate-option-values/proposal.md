## Why

`Options.validate/1` checks only the rules between keys. It does not check the value of each key. `parse/1` checks values, so every struct that comes from a URL is correct. A struct built by hand is not checked.

`CacheKey.derive/2` is public and takes a struct. It calls `validate/1` and then `normalize/1`. A hand-built struct with an out-of-domain value therefore gets a cache key from a string that `parse/1` refuses. Measured on `add-peaks-bit-depth`:

| Struct | `validate/1` | `normalize/1` | Re-parse |
|---|---|---|---|
| `%Options{format: :peaks, peak_bits: 24}` | `{:ok, _}` | `…/pk_bits:24/…` | error |
| `%Options{format: :peaks, channels: 3}` | `{:ok, _}` | `ch:3/…` | error |
| `%Options{format: :peaks, peak_count: 0}` | `{:ok, _}` | `…/pts:0` | error |

The `normalize/1` documentation says "The result always re-parses". That is true only for structs from `parse/1`.

The running proxy is not affected, because every struct it builds comes from `parse/1`. The gap is in the public API, and the second-opinion review of `add-peaks-bit-depth` found it.

## What Changes

- `validate/1` also checks the value of each field against the domain that `parse/1` accepts, and returns the same structured error.
- One definition of each domain serves both `parse/1` and `validate/1`, so the two cannot drift.
- A property test: for every generated struct, `validate/1` returns `{:ok, _}` only if `normalize/1` of that struct re-parses.

## Capabilities

### New Capabilities

None.

### Modified Capabilities

- `processing-options`: `validate/1` refuses an out-of-domain value on a hand-built struct.

## Impact

`lib/audio_proxy/options.ex` and its tests. No change to a URL, a cache key or a response. A struct from `parse/1` passes as before.
