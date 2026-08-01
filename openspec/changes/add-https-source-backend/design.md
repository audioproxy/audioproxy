## Context

Fills the HTTPS storage stub that `add-remote-files-source` ships. Small by construction: the seam is two functions, and one of them (`ffmpeg_input/1`) is the identity on the canonical URL.

## Goals / Non-Goals

**Goals:**
- HTTPS sources renderable end-to-end; the stub-pinning test replaced by behavior tests.

**Non-Goals:**
- Redirect following, retries, or connection pooling — the HEAD is one request against one allowlisted host, and ffmpeg does its own fetching for the render input.
- Caching HEAD results (`add-variant-cache` makes repeat traffic a HIT that never stats the source).

## Decisions

- **`:httpc` for the HEAD** — one control-plane request; wrapped in the source module, so a later swap (e.g. to `req` if the S3 client ever adopts it) is local. Explicit short timeout, TLS verification on (`:public_key.cacerts_get/0` — OTP ships the trust store hooks; a HEAD that skips verification would undermine the https-only policy).
- **No redirect following on HEAD**: a redirect answer (3xx) reports not-found rather than being chased — following would re-open the host-allowlist question at a second URL that was never authorized. ffmpeg's own fetch honors the same posture via the protocol whitelist; an origin that must redirect belongs behind its final hostname in the allowlist.
- **Unknown size is a first-class answer** (`size: nil`): streaming origins legitimately omit `Content-Length`; refusing them would make the proxy less capable than ffmpeg. The render byte cap is the enforcement backstop, as `add-render-endpoint`'s design already records.
- **ETag material**: origin `ETag` header when present, else `Last-Modified`, else none — degrading gracefully; the info endpoint's conditional-request quality follows what the origin provides.

## Risks / Trade-offs

- [HEAD and the later GET can disagree (origin changed between them)] → inherent to any stat-then-fetch design, harmless: the render sees the new bytes; cache identity is the URL, and `cb` exists for deliberate invalidation.
- [Origins that reject HEAD outright (405)] → reported not-found; documented. Supporting GET-with-Range probing is a follow-up if a real origin demands it.
