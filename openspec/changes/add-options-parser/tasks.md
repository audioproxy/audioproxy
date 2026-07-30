## 1. Parsing

- [x] 1.1 `%AudioProxy.Options{}` struct with typed fields for all §3 options
- [x] 1.2 Per-key parsers (format enum, int, float-with-precision-cap, multi-part `t`/`fade`/`norm`) returning structured errors
- [x] 1.3 `Options.parse/1` over the `/`-separated segments; unknown-key + duplicate-key errors

## 2. Validation

- [x] 2.1 Cross-key rules: `br` xor `q`; `bd` lossless-only; `pts`/`pk_fmt` require `f:peaks`; `sr` cap 48 kHz for lossy; `ch` ∈ {1,2}; non-negative times
- [x] 2.2 Unit tests: one failing case per rule, asserting the offending segment is named

## 3. Normalization & cache key

- [x] 3.1 `Options.normalize/1`: defaults materialized, keys sorted, canonical number rendering
- [x] 3.2 `CacheKey.derive(options, source)`: SHA-256 over normalized string + canonical source
- [x] 3.3 Unit tests: order insensitivity, default materialization, `cb` participation

## 4. Property tests

- [x] 4.1 StreamData generator for valid option combinations
- [x] 4.2 Properties: parse→normalize idempotent; segment-order permutation ⇒ same normalized form + same cache key; distinct normalized forms ⇒ distinct cache keys
- [x] 4.3 Property: normalized string always re-parses without error (grammar closure)

## 5. Docs

- [x] 5.1 Update README: supported options table, validation rules, cache-key semantics
