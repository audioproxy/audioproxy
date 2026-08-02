## Context

Header-level work throughout — no new processes, no deps, all `Plug.Test`-able. The organizing principle: state intent explicitly on every response class, because CDN defaults are where Cloudflare, CloudFront, and Fastly differ most; explicitness is what makes behavior portable across them.

## Goals / Non-Goals

**Goals:**
- No response leaves without a deliberate `Cache-Control`; revalidation and HEAD cost no renders.

**Non-Goals:**
- HIT-path serving (302 `no-store`, 206, `Accept-Ranges` — `add-variant-cache`, which lands on top of this).
- CDN purge APIs / invalidation tooling (`cb` is the supported invalidation; active purge is operator tooling this project doesn't own).
- Origin-authentication headers (the URL signature already gates the origin).
- `Vary` handling beyond not emitting one (no content negotiation exists to vary on).

## Decisions

- **Error TTLs are class-derived, not configurable**: 404 at 10 s balances "source appears after upload" against origin protection; 401/422 at 60 s because they are pure functions of the URL (a bad signature never becomes good; invalid options never become valid — only a deploy changes that, and 60 s bounds the confusion window); 429/5xx `no-store` because caching a transient failure amplifies it. Knobs deferred until someone demonstrates a need.
- **413/415 follow the 404 row (`max-age=10`)** — decided during apply, where the class list left them unstated: both are verdicts about the *current source bytes* (too large, undecodable), and a re-upload changes the verdict the same way it makes a 404 stop being one. The derivation lives in one `ErrorJSON.cache_control/1` with no default clause, so a status added later without a stated policy crashes its own slice's tests rather than inheriting one.
- **304 short-circuit placement**: after `VerifySignature` + `ParseOptions` + `ResolveSource` (the ETag needs the normalized options and canonical source), before stat/render. Deliberately *not* before signature — a 304/200 oracle for unsigned probes would leak which variants exist.
- **HEAD via explicit router match**, not middleware magic: `head "/:sig/*rest"` routing into the same plug chain with a bodiless terminal step. The action runs every check including stat (a HEAD that lies about 404s is worse than none) and skips only the spawn.
- **`no-transform` appended to the existing `@cache_control`** constant — one definition, every media response.
- **Range ignored by simply not reading the header** on the MISS path — the requirement exists to pin that this is intended (RFC 9110 §14.2 allows it), with a test, so a future "helpful" 416 or partial-implementation drift fails loudly.

## Risks / Trade-offs

- [60 s cached 401s can mask a just-fixed signature during key rotation] → bounded and rare; rotation is a deploy-scale event, and 60 s is far below CDN default negative TTLs it replaces.
- [HEAD runs a stat per request — cheap but nonzero] → identical cost profile to GET's check chain; no new amplification surface (signature still gates).
- [304 depends on ETag stability across releases] → ETag = cache key, whose stability is already load-bearing for the entire variant store; nothing new rests on it.
