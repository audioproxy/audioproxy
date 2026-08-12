# Add CORS Configuration

## Why

The proxy sends no CORS headers, deliberately — and for `<audio src>` playback that is correct, since media elements play cross-origin without them. But anything that *reads* the bytes from a browser breaks: a page on another origin cannot `fetch()` `f:peaks` JSON to draw a waveform, cannot read `/info`, cannot even see `Retry-After` on a 429 to implement polite backoff. That is not an edge case; it is the primary consumption pattern of the peaks endpoint — every peaks.js-style player fetches waveform data from a web app whose origin is not the proxy's. The concrete forcing case is the marketing site's playground (a browser page on `audioproxy.dev` fetching peaks from `playground.audioproxy.dev`), but the gap belongs to every browser consumer.

imgproxy names the precedent and the semantics: *"IMGPROXY_ALLOW_ORIGIN: when specified, enables CORS headers with the provided origin. CORS headers are disabled by default."* Same shape here.

## What Changes

- **`AP_ALLOW_ORIGIN`**: a single origin (scheme + host + optional port) or `*`. Unset — the default — is exactly today's behavior: no CORS headers anywhere, and OPTIONS answers 404 like every other non-GET method.
- When set, every main-listener response — success and error alike, since a fetching page must be able to read the §5 error envelope — carries:
  - `Access-Control-Allow-Origin: <value>`
  - `Vary: Origin` (when the value is not `*`)
  - `Access-Control-Expose-Headers: x-audio-proxy, retry-after, accept-ranges, etag` — without this the browser hides exactly the headers a client needs: `Retry-After` is *not* CORS-safelisted, so a cross-origin page could see a 429 but not how long to wait, and the HIT/MISS/COALESCED header would be invisible to the one audience that reads it programmatically.
- When set, **`OPTIONS` answers 204** with `Access-Control-Allow-Methods: GET, HEAD`, echoed `Access-Control-Allow-Headers` (from `Access-Control-Request-Headers`), and `Access-Control-Max-Age: 86400`. This carves the single deliberate exception into the API doc's "methods other than GET answer 404, everywhere" rule — scoped to preflight, only when CORS is enabled, and the 204 confirms nothing a 404 would not (the origin already knows the proxy is CORS-enabled for it).
- `/metrics` is out of scope: it lives on its own loopback-bound listener, and cross-origin browser access to it is not a use case.

## Non-goals

- Multiple origins / origin lists. imgproxy takes one value; one value covers the known cases. A list is a straightforward extension if a deployment ever needs it, and starting single keeps the `Vary` story trivial.
- Credentials (`Access-Control-Allow-Credentials`). The API is bearer-URL-authenticated; cookies have no role.
- Any change to what plays in an `<audio>` element — that worked without CORS and continues to.

## Capabilities

### New Capabilities

<!-- none -->

### Modified Capabilities

- `render-http`: optional CORS response headers and a preflight handler, gated on `AP_ALLOW_ORIGIN`, default off and byte-identical to today.

## Impact

- Modified: `AudioProxy.Config` (one var, origin-shape validation at boot), the router/response path (header injection + OPTIONS route), README configuration table, `docs/audio-proxy-api-v1.md` §2 (the non-GET rule gains its carve-out sentence) and §6, `llms-full.txt` config table.
- Default-off equivalence pinned by a test: with `AP_ALLOW_ORIGIN` unset, responses are byte-identical to before and OPTIONS is 404.
- Tests: header presence on 200/302/4xx/5xx; expose-headers lets a fetch read `Retry-After` off a 429; preflight 204 shape; `*` versus explicit origin (`Vary` present only for the latter); invalid origin value aborts boot naming the var.
- Estimated well under the slice budget (~150 LOC).
- Position: **next up — requested for the earliest possible release.** No dependency on any active change.
