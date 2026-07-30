## Context

CLAUDE.md render policy: render at full speed into the write-back; clients lag the render. The tee is therefore just another coalescing subscriber — one that consumes eagerly and uploads via the S3 layer's multipart stream.

## Goals / Non-Goals

**Goals:**
- Byte-exact write-back, atomic-or-absent variants, HIT paths in both serve modes.

**Non-Goals:**
- Cache eviction/TTL (bucket lifecycle rules are the operator's tool); eager peaks alongside variants (noted as future work in API doc §3.3).

## Decisions

- **Tee as a supervised Task subscriber** started by the coordinator when `AP_VARIANT_BUCKET` is set. Multipart upload gives atomicity for free: parts only materialize as an object on `CompleteMultipartUpload`, abort on render error/cancel — "no partial persistence" without temp objects or renames.
- **Client-disconnect policy changes with cache on**: the tee counts as a subscriber, so last-*client*-gone no longer cancels the render — it completes into the bucket (a disconnecting client usually retries; next time it's a HIT). With cache off, prior behavior (cancel) stands. This amends the coalescing slice's "last subscriber" rule naturally — the tee *is* a subscriber.
- **HIT check placement**: HEAD variant bucket after options/source resolution, before semaphore/coalescing. In-flight renders are still coalesced (registry checked after cache miss) — order: cache → registry → new render.
- **Presigned HIT URL TTL** short (default 300 s) — the 302 target is per-request; long-lived caching belongs to the immutable variant URL itself, which CDNs cache by our Cache-Control headers.
- **Proxy mode** streams the store's GET (with request Range forwarded verbatim) through `chunk/2`, passing through `Content-Length`/`Content-Range`/206 — no local buffering.

## Risks / Trade-offs

- [HEAD-then-render race: two nodes/timing could double-render] → harmless: multipart complete is last-write-wins with identical bytes (deterministic argv ⇒ identical variants).
- [Tee keeps CPU busy for content nobody awaits] → bounded by preview-sized outputs; the alternative (cancel + partial-abort) wastes the near-complete work instead. Config escape hatch deferred until real-world data says otherwise.
