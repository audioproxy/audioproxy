## 1. Endpoint

- [ ] 1.1 Payload decoder: base64url JSON list → per-entry `{options, source}` parse/validate/authorize via existing modules; entry limit; structured per-entry errors
- [ ] 1.2 Warm action: store HIT check per entry → subscribe-and-release into the coalescing registry (tee completes the render); assemble per-entry report (`hit`/`started`/`invalid`/`rejected`); 422 without `AP_VARIANT_STORE`
- [ ] 1.3 Route `GET /:sig/warm/*payload` through the signature plug

## 2. Tests

- [ ] 2.1 Unit: payload decoding (undecodable, oversized, mixed validity), report shapes, store-required 422
- [ ] 2.2 Integration (`@tag :ffmpeg`): cold batch → prompt response, variants appear in store afterwards (poll store, not endpoint); repeat batch → all `hit`; disconnect-after-response → renders still complete
- [ ] 2.3 Governance: warm entry duplicating an in-flight interactive render coalesces (one subprocess); saturated queue → `rejected` entries reported; entry limit enforced
- [ ] 2.4 CaptureLog: warm requests log through the request-logging line like any request; no new log surface

## 3. Docs

- [ ] 3.1 README (PRO section) + `docs/`: payload format with a worked signed example, fire-and-forget semantics ("started ≠ completed; correctness never depends on warming"), entry limit and its URL-length rationale, interim queue-fairness note
