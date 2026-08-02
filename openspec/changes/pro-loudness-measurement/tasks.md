## 1. Analysis mode

- [ ] 1.1 Command builder: loudness-analysis argv mode (`loudnorm=print_format=json`, null muxer); vocabulary/allowlist tests extended
- [ ] 1.2 Stderr-as-payload capture path in the measure action: parse trailing JSON block on exit 0; nonzero → existing failure classification
- [ ] 1.3 Unit tests: canned loudnorm stderr fixtures → parsed contract; malformed/interleaved stderr → error

## 2. Endpoint

- [ ] 2.1 `measure` as exclusive pseudo-option (422 with any other option); route + action: resolve → stat → coalesced, slot-governed analysis → JSON response
- [ ] 2.2 ETag (source identity + source ETag) + `If-None-Match`/304 + Cache-Control, reusing the conditional machinery
- [ ] 2.3 Error mapping: 404/415/504/429 through the existing table

## 3. Tests

- [ ] 3.1 Integration (`@tag :ffmpeg`): lavfi sine at known level → `input_i`/`input_tp` within tolerance; loud-then-silent fixture → full-duration measurement; text file → 415
- [ ] 3.2 Coalescing: concurrent measures → one subprocess (spy), identical results; semaphore saturation → queue then 429 on overflow
- [ ] 3.3 304 revalidation without an analysis pass (process-table probe)

## 4. Docs

- [ ] 4.1 README (PRO section) + `docs/`: endpoint contract, tolerance semantics, "apply via `gain:` today" guidance, two-pass grammar extension named as future work
