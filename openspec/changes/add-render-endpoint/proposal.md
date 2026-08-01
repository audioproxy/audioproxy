## Why

With `add-request-plugs` in place, a valid render request reaches a pinned 501. This slice replaces it with the streaming action — the MVP's core behavior: spawn ffmpeg via the port pipeline and stream chunked 200 per API doc §5. Split from the plumbing so each PR stays within the review-size target.

## What Changes

- The render action: `Source.ffmpeg_input/1` handoff (TOCTOU posture decided and recorded), spawn `Ffmpeg.Render` with the endpoint process as consumer, chunked streaming receive-loop.
- Response headers per §5 on the 200: Content-Type, `Cache-Control: public, max-age=31536000, immutable`, `ETag` = cache key, `X-Audio-Proxy: MISS`, `Content-Disposition` for `dl`. (`COALESCED` arrives with `add-render-coalescing`.)
- Client-disconnect detection → cancel the render (pipeline's consumer-down kill as backstop; no orphans per CLAUDE.md).
- Render-produced errors become reachable: 415 (undecodable) and 504 (timeout) flow through the existing ErrorJSON table; mid-stream failure after 200 terminates the chunked stream abnormally.
- Full-stack test harness over a real socket (Bandit + local fixtures + real ffmpeg; `:gen_tcp` for disconnect/timing assertions).

## Capabilities

### New Capabilities

<!-- none -->

### Modified Capabilities

- `render-http`: gains the streaming requirements (chunked 200, §5 headers, disconnect, render-failure reachability); the 501 placeholder requirement is removed.

## Impact

- Modified: the action in the router; removes the 501 pinning test.
- Depends on: `add-request-plugs` (the seam it fills), `add-ffmpeg-port-pipeline`, `add-local-files-source`.
- Blocks: `add-docker-release` (the MVP surface it smoke-tests), `add-render-coalescing` (swaps the spawn call), `add-variant-cache`, `add-peaks-format`.
