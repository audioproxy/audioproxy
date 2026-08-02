## Why

The API is already CDN-shaped — URL = immutable variant identity, `ETag` = cache key, no cookies, `cb` busts every tier at once. What's missing is discipline at the edges: error responses carry no `Cache-Control` at all (CDN negative-caching defaults decide how long a 404 sticks), a CDN revalidation triggers a full re-render even though the ETag is derivable from the URL alone, HEAD answers 404, and Range-on-MISS behavior is accidental rather than spec'd. Every gap is the proxy failing to state intent explicitly — and CDN defaults, where Cloudflare/CloudFront/Fastly differ most, filling the silence.

## What Changes

- **Error cacheability, per class**: 404 `max-age=10` (sources appear), 401/422 `max-age=60` (deterministic per URL), 429 and 5xx-class/504 `no-store` (transient; `Retry-After` already present on 429).
- **`no-transform`** appended to the media `Cache-Control` (audio bytes and `.dat` peaks must survive edge features that recompress or mangle bodies).
- **Zero-work conditional responses**: `If-None-Match` matching the URL-derived `ETag` answers `304` with no render, no storage access — pure computation. A CDN revalidating an evicted object costs microseconds instead of an ffmpeg spawn.
- **HEAD support** on the signed endpoints: identical status and headers to GET (through the full check chain incl. source stat), empty body, no render subprocess.
- **Range-on-MISS spec'd**: a `Range` header on an uncached render answers the full `200` stream (RFC 9110 permits ignoring Range); 206 remains the variant cache's HIT-path concern.

## Capabilities

### New Capabilities

- `edge-caching`: Explicit cacheability for every response class, conditional-request handling, HEAD semantics, and Range-on-MISS behavior.

### Modified Capabilities

<!-- none — render-http behavior is extended additively; the variant-cache slice (later) inherits this discipline for HIT paths -->

## Impact

- Modified: `ErrorJSON` (per-class cache-control), render action (`no-transform`, If-None-Match short-circuit, Range ignore), router (HEAD matching).
- Depends on: merged code only (render endpoint, request plugs).
- Position: after `add-render-semaphore`, before `add-variant-cache` — the cache slice's HIT paths (302, 206) then land on top of stated discipline (its 302 `no-store` amendment is applied alongside this proposal).
