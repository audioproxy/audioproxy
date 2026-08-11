# Tasks

## 1. Option class

- [ ] 1.1 Options parser: variant/request class metadata per key; request options excluded from the canonical options string, cache key, and ffmpeg args; duplicates still rejected per the existing rule
- [ ] 1.2 `exp:<unix-seconds>` — bounded positive integer validation (numeric-bounds rule), past values valid grammar
- [ ] 1.3 Round-trip property per class: variant options → identical cache key; request options → signed path only; URLs differing only in `exp` → identical cache key, identical argv, coalesced render

## 2. Enforcement

- [ ] 2.1 Expiry check after signature verification, before source resolution; 410 with the new `expired` error row (`@representative_errors` + clause-count test)
- [ ] 2.2 Cache-Control clamp on successful responses: `max-age ≤ exp − now`
- [ ] 2.3 Presign-TTL clamp on HIT redirects: `min(AP_PRESIGN_TTL, exp − now)`
- [ ] 2.4 The 410 carries an explicit cacheable `Cache-Control`

## 3. Tests

- [ ] 3.1 410 semantics: expired → no source access, no subprocess (assert via a source that would fail loudly); live → identical behavior and cache key as without `exp`
- [ ] 3.2 Both clamps against a HIT (store-backed): response `max-age` and presigned URL expiry each bounded by `exp − now`
- [ ] 3.3 Signature coverage: altering `exp` without re-signing fails verification
- [ ] 3.4 Coalescing: two URLs differing only in `exp`, one render, both served

## 4. Docs

- [ ] 4.1 API doc §3 (option class distinction + `exp` row) and §5 (`expired` → 410); README options table and signing section
- [ ] 4.2 `llms-full.txt` options and error tables (both guarded; recompute nothing — the signing example is unchanged, `exp` is ordinary path bytes)
- [ ] 4.3 Rails gem issue: `expires_in:`/`expires_at:` sugar (separate repo, filed when this merges); docs site guides follow via drift notifier
