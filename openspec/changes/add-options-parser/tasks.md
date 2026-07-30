## 1. Parsing

- [ ] 1.1 `%AudioProxy.Options{}` struct with typed fields for all §3 options
- [ ] 1.2 Per-key parsers (format enum, int, float-with-precision-cap, multi-part `t`/`fade`/`norm`) returning structured errors
- [ ] 1.3 `Options.parse/1` over the `/`-separated segments; unknown-key + duplicate-key errors

## 2. Validation

- [ ] 2.1 Cross-key rules: `br` xor `q`; `bd` lossless-only; `pts`/`pk_fmt` require `f:peaks`; `sr` cap 48 kHz for lossy; `ch` ∈ {1,2}; non-negative times
- [ ] 2.2 Unit tests: one failing case per rule, asserting the offending segment is named

## 3. Normalization & cache key

- [ ] 3.1 `Options.normalize/1`: defaults materialized, keys sorted, canonical number rendering
- [ ] 3.2 `CacheKey.derive(options, source)`: SHA-256 over normalized string + canonical source
- [ ] 3.3 Unit tests: order insensitivity, default materialization, `cb` participation

## 4. Property tests

- [ ] 4.1 StreamData generator for valid option combinations
- [ ] 4.2 Properties: parse→normalize idempotent; segment-order permutation ⇒ same normalized form + same cache key; distinct normalized forms ⇒ distinct cache keys
- [ ] 4.3 Property: normalized string always re-parses without error (grammar closure)

## 5. Docs

- [ ] 5.1 Update README: supported options table, validation rules, cache-key semantics
