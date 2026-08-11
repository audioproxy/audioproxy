# Add Expiring URLs

## Why

Every signed URL is currently an eternal bearer capability: the HMAC covers the path and nothing else, so a leaked URL works forever and the only revocation is rotating the key — which kills every URL ever issued. Time-boxed access (press previews, invitation-scoped listening, paid content) is a normal deployment shape with no answer today. imgproxy ships `expires` in OSS; parity plus the strength it adds to the signing story puts it in OSS here too, and the Rails gem wants it (`expires_in:` sugar).

The design cost worth a proposal is not the clock check — it is that a naive `exp` option would violate the cache-key doctrine: options double as the cache key, so per-user expiry timestamps would mint per-user cache keys and fragment the cache into one render per listener. The fix is a new *class* of option, and building the class once also creates the seam `pro-render-priority` needs.

## What Changes

- **A request-option class.** Options split into *variant options* (everything today: normalize into the canonical options string, the cache key, the ffmpeg args) and *request options*: parsed and validated in the options segment, covered by the signature automatically (they are path bytes), but excluded from the canonical options string, the cache key, and the ffmpeg args. Two URLs differing only in request options share one cache key and coalesce into one render. The round-trip property gains a class-aware statement: variant options round-trip to an identical cache key; request options round-trip to the signed path only.
- **`exp:<unix-seconds>`**, the first request option. Bounded positive integer per the numeric-bounds rule; duplicate `exp` rejected like any duplicate option. A request arriving after its `exp` answers **410 Gone** — a new error-table row (`ErrorJSON`'s `@representative_errors` gains it, so the llms guard forces the doc row). The 410 is cacheable with an explicit `Cache-Control`: an expired URL can never become valid again, so edges may keep the verdict.
- **Expiry caps every credential and cache lifetime the response hands out:**
  - Response `Cache-Control` on 200s clamps `max-age` to `min(configured, exp − now)` — otherwise a CDN serves the cached body past expiry and enforcement at the proxy is theater.
  - HIT-redirect presigning clamps the presigned URL's TTL to `min(AP_PRESIGN_TTL, exp − now)` — otherwise the 302 trades an expiring URL for a storage URL that outlives it.
- No clock-skew leeway: a generator pads its own timestamps. `exp` values in the past are still *valid grammar* (they sign and parse) — they simply answer 410, which is what lets the 410 be cacheable.

## Non-goals

- **`/info` expiry.** The info path has no options segment (`/{sig}/info/{source}`), so `exp` cannot ride it without a grammar change; info URLs are operator-to-operator, not shared with end users. If demand appears, extending the grammar is its own small change — named here as `add-info-request-options`, proposed only on demand.
- **Revocation of a specific URL before its time.** That is key rotation; a multiple-accepted-keys scheme (imgproxy-style staged rotation) is a separate future change.
- Any PRO behavior. This change only creates the request-option class; `pro-render-priority` adds its member in the PRO tree.

## Capabilities

### New Capabilities

<!-- none -->

### Modified Capabilities

- `processing-options`: the variant/request option class split, `exp` as the first request option, cache-key exclusion.
- `url-signing`: expiry verification order (after signature verification, before source resolution), the 410 row.
- `edge-caching`: the `max-age` and presign-TTL clamps.

## Impact

- Modified: options parser (option class metadata, `exp` validation), cache-key normalization (class-aware), the request path (410 before any source or render work), variant serving (Cache-Control clamp, presign clamp), `ErrorJSON` (+ its clause-count test), API doc §3/§5, README options table, `llms-full.txt` options and error tables (both guarded).
- Rails gem follow-up (separate repo): `expires_in:`/`expires_at:` computing `exp` at URL-build time — which gives apps rotation for free: each page view mints a fresh short-lived URL while all of them share one cached variant.
- Tests: property — URLs differing only in `exp` produce identical cache keys and coalesce; round-trip per class; 410 semantics incl. cacheability; both clamps, each asserted against a HIT (the presign clamp needs a store).
- Estimated ~300 LOC including tests.
- Position: ready when picked up — no dependency on any active change; sequences naturally before `pro-render-priority`'s extraction (which consumes the class).
