## Context

Second `pro-` slice, extraction-structured like the first (prefixed change and capability, zero amendments elsewhere). The honest framing from the exploration holds: N parallel GETs already warm correctly; this endpoint is ergonomics (one signed request, no held connections) plus the substrate later PRO rungs trigger from events.

## Goals / Non-Goals

**Goals:**
- Fire-and-forget batch warming that adds no state, no queue, and no failure modes the lazy path doesn't already handle.

**Non-Goals:**
- Upload policies / event triggers (the next rung — it calls this machinery).
- Priority classes (warm renders queue FIFO with everything else until the semaphore grows classes; recorded, not built).
- Job status API — deliberately absent. Progress is observable by GETting the variant URL; "queued" is the coalescing registry.
- POST bodies. The payload rides in the URL (`enc/` pattern), keeping "URLs are the entire API" intact; the entry limit keeps URLs within practical length bounds.

## Decisions

- **Outer signature authorizes the batch**: entries are `{options}/{source}` paths *without* per-entry signatures — the operator signing the warm URL vouches for the list. Inner entries still pass full options/source validation and allowlists; the signature shortcut skips only the HMAC-per-entry, not any safety check.
- **Response is a per-entry report, not a promise**: `hit | started | invalid(reason) | rejected(queue_full)`. `started` means "handed to the registry," nothing stronger — the fire-and-forget contract is that nothing downstream depends on warm completion (correctness comes from lazy rendering; warming only moves cost earlier).
- **Warm renders detach from the requester**: the warm action subscribes-and-releases — the tee (variant-cache's write-back subscriber) is the surviving consumer, so the render completes into the store with no client attached. This is exactly the cache-on disconnect policy the variant-cache slice already defines; the warm path leans on it rather than inventing detached-render machinery.
- **Queue overflow reported, not retried**: the endpoint does not retry internally (retry state is state). The caller retries rejected entries; bulk-migration pacing lives with the caller or the future policy engine.
- **Entry limit 100** as a constant, not config — a limit chosen to keep signed URLs comfortably under practical URL-length ceilings (~8 KB); raising it is a code change with that math attached.

## Risks / Trade-offs

- [A large warm batch can occupy the whole render queue ahead of interactive traffic] → visible (rejected entries, 429-equivalent per entry) and bounded (entry limit); the real fix is semaphore priority classes, which arrive with upload policies — this slice's queue behavior is explicitly interim.
- [URL-borne payloads leak into access logs] → entries are variant descriptions, not secrets (same content as any render URL); the logging slice's no-credentials guarantee is unaffected.
- [Warming into a store that evicts immediately (full disk)] → the write-back failure path already logs and instruments; warm reports `started` honestly — it promised a render, not retention.
