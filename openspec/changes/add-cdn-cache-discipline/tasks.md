## 1. Cacheability

- [ ] 1.1 `ErrorJSON` gains per-class `Cache-Control` (404 → `max-age=10`; 401/422 → `max-age=60`; 429/5xx/504 → `no-store`)
- [ ] 1.2 `no-transform` appended to the media `@cache_control`
- [ ] 1.3 Tests: every error status carries its documented `Cache-Control`; media 200s carry `no-transform`

## 2. Conditional requests

- [ ] 2.1 If-None-Match short-circuit in the render action (post-plugs, pre-stat): match → 304 with ETag + Cache-Control, no body, no spawn, no store access
- [ ] 2.2 Tests: match → 304 (assert no subprocess via process-table probe); mismatch → normal 200; unsigned + match → 401

## 3. HEAD

- [ ] 3.1 `head "/:sig/*rest"` route through the existing plug chain; bodiless terminal step after stat (200 with Content-Type/Cache-Control/ETag; errors as GET, bodiless)
- [ ] 3.2 Tests: valid URL → 200 headers + empty body + no spawn; bad signature → 401; missing source → 404; HEAD on `/health`

## 4. Range on MISS

- [ ] 4.1 Test pinning the behavior: `Range` header on an uncached render → full 200 chunked, no `Accept-Ranges`, no 206/416

## 5. Docs

- [ ] 5.1 Update README (ops): cacheability table per response class, CDN-facing behavior summary (revalidation, HEAD, Range-on-MISS); note HIT-path Range/redirect discipline arrives with the variant cache
