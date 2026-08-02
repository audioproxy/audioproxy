## Why

With `add-variant-store` persisting completed renders, this slice makes them pay off: requests whose cache key exists in the store are served without rendering — proxied with full Range support, or redirected where the backend can presign. Split from the storage machinery per the review-size convention; this half owns everything a client can observe about a HIT.

## What Changes

- HIT detection before coalescing (`head/1`; order: cache → registry → new render), `X-Audio-Proxy: HIT`.
- **Proxy mode**: stream from the store with `Content-Length` (the size is known — declaring it is what buys seeking and resumption), `Accept-Ranges`, and `206`/`Content-Range` for Range requests; progressive delivery, no whole-object buffering.
- **Redirect mode** (backends with `presign`): `302` to a short-lived presigned URL, the redirect itself `Cache-Control: no-store` — a cached 302 hands out expired presigned URLs.
- **The framing contract**: the same URL is a chunked, non-seekable `200` on a MISS and a length-declared, range-capable response on a HIT; clients must not assume one framing. Spec'd, with the client-contract invariant: what a client observes is a property of cache state, never of the configured backend.

## Capabilities

### New Capabilities

<!-- none -->

### Modified Capabilities

- `variant-cache`: gains the serving requirements (HIT paths, Range/206, framing, backend-invariant client contract) on the capability `add-variant-store` creates.
- `render-http`: the render endpoint checks the store before coalescing and serves HITs per §5.

## Impact

- New: HIT lookup + serving branch in the render action.
- Modified: render endpoint action, API doc §5, README cache semantics.
- Depends on: `add-variant-store` (the store it serves from), `add-cdn-cache-discipline` (the header discipline HITs inherit).
- The S3 backend and its backend-parity suite live in `add-s3-client`; nothing here changes when it lands.
