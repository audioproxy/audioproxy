# Tasks

## 1. Codec
- [ ] 1.1 Envelope encode/decode: base64url, size bound, strict JSON parse mapped to invalid-option
- [ ] 1.2 Canonicalization: sorted keys, number normalization, significant array order
## 2. Tests
- [ ] 2.1 Property: canonicalize(parse(render(p))) is stable and spelling-independent
- [ ] 2.2 Bounds and malformed-input fuzzing (truncated base64, non-JSON, deep nesting)
## 3. Docs
- [ ] 3.1 PRO contract doc: envelope, bounds, the variant/request payload class rule
