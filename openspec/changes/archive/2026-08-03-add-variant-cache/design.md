## Context

Serving half of the former single change. The store, tee, and metadata persistence exist (`add-variant-store`); this slice reads them back out and defines everything a client can observe about a HIT.

## Goals / Non-Goals

**Goals:**
- HIT paths in both serve modes, backend-invariant to the client; the MISS/HIT framing contract stated and tested.

**Non-Goals:**
- Storage machinery (landed); S3 backend + parity suite (`add-s3-client`); eager peaks (future per API doc §3.3).

## Decisions

- **HIT check placement**: `head/1` after options/source resolution, before semaphore and coalescing — order: cache → registry → new render. In-flight renders still coalesce.
- **Proxy mode streams `get_stream/2`** with the request Range forwarded, passing `Content-Length`/`Content-Range`/206 through without buffering; the local backend serves file slices — no `X-Sendfile`-style handoff (assumes a reverse proxy this project does not require).
- **Presigned HIT URL TTL** short (default 300 s), presigning backends only; the 302 carries `Cache-Control: no-store` (its Location is a 300 s credential — the immutable policy belongs to variant bytes, never to the redirect pointing at them).
- **Conditional requests on HITs** reuse the cdn-discipline machinery (pure-URL ETag → 304) — no second implementation.

## Risks / Trade-offs

- [head-then-render race: two nodes could double-render] → harmless: deterministic argv means identical bytes; both stores converge on the same content.
- [Redirect mode routes media bytes around a CDN] → known and recorded: behind a CDN, proxy mode is the collaborating mode. The missing flavor — redirect to a stable, CDN-fronted public base URL over the store (`public_url/1` capability + `AP_VARIANT_PUBLIC_BASE`) — needs a deployment that wants it before it earns a slice.
