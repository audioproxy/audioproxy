# Fix HEAD Response Headers

## Why

A `HEAD` on a cached variant omits three headers its `GET` sends, measured against v0.7.0 on the same warmed URL:

```
GET                                   HEAD
x-audio-proxy: HIT                    (absent)
content-length: 114026                (absent)
accept-ranges: bytes                  (absent)
etag, cache-control, content-type      same
```

RFC 9110 §9.3.2 says a server SHOULD send the same header fields for `HEAD` as it would for `GET`, and MAY omit only those "for which a value is determined only while generating the content". On a **hit** none of these three qualify: the length, the range support and the cache verdict are all known from the store's metadata before a byte moves. The proxy is not choosing a permitted omission; it is answering a different question than the one asked.

The practical cost is that `HEAD`, the method whose entire purpose is asking about a resource cheaply, cannot answer the three things a client most wants to know:

- **How big is this variant?** `content-length` on a `HEAD` is the standard way to size a download without fetching it. Download managers and players do this by reflex.
- **Can I seek?** A client probing `accept-ranges` before deciding whether to offer scrubbing concludes the proxy has no range support, which is the opposite of true for a hit.
- **Is this cached?** A cheap cache probe is the natural way to distinguish "this will be instant" from "this will render", and the header exists precisely to say so. This was found while building the playground explorer, which wanted exactly that probe and had no way to get it: an `<audio>` element exposes no response headers, and `HEAD` returned nothing to read.

The header is documented in the API contract as part of the response, without a carve-out saying `HEAD` is exempt, so today's behavior is also a contract deviation rather than only an ergonomic one.

## What Changes

- **On a hit, `HEAD` matches `GET` header-for-header**, body excluded: `x-audio-proxy`, `content-length`, `accept-ranges`, `etag`, `cache-control`, `content-type`. In redirect serve mode it matches the `302` a `GET` would produce, including `location` and its `no-store`.
- **On a miss, `HEAD` reports what is knowable without rendering** and stays cheap: `x-audio-proxy: MISS`, `content-type` from the options, and `cache-control`. `content-length` and `accept-ranges` are legitimately absent here, because for a stream that has not been rendered they *are* values determined only while generating the content, which is exactly the omission the RFC permits.
- **`HEAD` never starts a render, never takes a semaphore slot, and never writes to the variant store.** This is the safety property that makes the rest of the change acceptable: a flood of `HEAD`s must remain cheap, or the probe becomes a denial-of-service lever. Today's implementation already ends after the stat; this change keeps that and only adds headers.
- Every gate a `GET` passes still applies unchanged: signature, expiry, allowlist, byte caps. A `HEAD` must not become a way to learn whether a variant exists without a valid signature.
- The API doc gains a short subsection stating the two `HEAD` shapes, so the difference is contract rather than accident.

## Non-goals

- Making `HEAD` render, warm, or queue anything. Warming is `pro-warm-endpoint`'s job and deliberately not a side effect of a probe.
- `Range` handling on `HEAD`.
- The `vary: accept-encoding` that appears on `HEAD` but not `GET` (noticed in the same measurement, likely added below us by the HTTP layer). Worth its own look; not this change.

## Capabilities

### Modified Capabilities

- `render-http`: `HEAD` responses carry the same headers as `GET` where the values are known without rendering, with the miss case specified rather than incidental.

## Impact

- Modified: the render action's bodiless path, API doc §5, and whatever README line describes `x-audio-proxy`.
- Tests: header-for-header equality between `GET` and `HEAD` on a hit (asserted as a set difference, so a header added to `GET` later cannot silently skip `HEAD`); the miss shape; a proof that `HEAD` on a cold variant spawns no render (no slot taken, store still empty afterwards, which is also the regression guard for the safety property); signature and expiry still enforced.
- No new configuration, no new dependencies. Estimated ~120 LOC including tests.
- Position: ready when picked up. Small, self-contained, and it removes a documented-contract deviation.
