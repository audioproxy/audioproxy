## 1. Backend

- [ ] 1.1 HTTPS `stat/1`: `:httpc` HEAD (short timeout, TLS verification on) → `%{size: n | nil, etag_material: …}`; 3xx/4xx/5xx/transport failure → `:not_found`
- [ ] 1.2 HTTPS `ffmpeg_input/1`: the canonical URL; remove the HTTPS "no backend" stub and its pinning test (S3's stays)

## 2. Tests

- [ ] 2.1 Against a stub origin (Bandit): size present, size absent (unknown-size answer), 404, 405, 3xx not followed, connection refused, timeout
- [ ] 2.2 ETag-material derivation: ETag header, Last-Modified fallback, neither
- [ ] 2.3 End-to-end (`@tag :ffmpeg`): render an HTTPS source served by the stub origin → decodable output; unreachable origin → 404 through the endpoint

## 3. Docs

- [ ] 3.1 `docs/sources.md`: HTTPS fetch semantics (HEAD behavior, unknown-size policy, no-redirect rule and the allowlist rationale); README note that HTTPS sources are now renderable
