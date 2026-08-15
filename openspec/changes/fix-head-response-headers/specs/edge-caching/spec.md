## REMOVED Requirements

### Requirement: HEAD is supported on signed endpoints
**Reason**: `render-http` now owns `HEAD` in full, and this requirement describes behavior that no longer exists — it mandates the source stat as part of every `HEAD`, which a cache hit skips, and it predates the cache lookup entirely. Leaving it here would put two `HEAD` requirements in two capabilities, one of them wrong.

**Migration**: None for clients — the new requirements are a superset. What this one pinned is covered by *HEAD carries the headers a GET would* (status, `Content-Type`, `Cache-Control`, `ETag`, empty body), *HEAD never renders* (no ffmpeg process), and the *Gates still apply* scenario (401 and 404 identical to the `GET`).
