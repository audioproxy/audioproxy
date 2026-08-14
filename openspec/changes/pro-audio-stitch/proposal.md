# PRO: Audio Stitching

## Why

Intro + episode + outro as one URL: sequential composition, the sibling of mixing's simultaneous composition. Cloudinary does not offer audio splicing at all; podcast tooling reaches for it constantly (dynamic pre/post-roll without re-uploading episodes). Same payload envelope, same N-source resolution, a different filter (`concat`, optionally `acrossfade`).

## What Changes

- A `stitch:{payload}` variant option: an ordered source list `[{src}, {src, xfade}, ...]`, where `xfade` seconds crossfades a segment into its predecessor (default hard cut).
- Variant-defining payload (cache key), same rules as mix. Segment count capped (default 8).
- Render: sources resolve through existing types; sample-rate/channel alignment is normalized in the graph before `concat`; one process, one slot. Downstream options apply to the stitched program.

## Non-goals

- Gapless-precision claims for lossy segment boundaries (documented, not promised); mixing and watermarks (their own changes); per-segment processing beyond `xfade` (a segment needing its own trim is expressed by pointing at a variant URL as its source - which existing `https://` sourcing already permits, worth a worked example rather than new machinery).

## Capabilities

### New Capabilities
- `pro-audio-stitch`: ordered concatenation via signed payload - schema, crossfades, alignment, cache-key participation.

### Modified Capabilities
<!-- none -->

## Impact

- Depends on: `pro-request-payloads`. Shares resolution orchestration with `pro-audio-mix` (build once, consume twice).
- Tests: rendered duration equals the sum minus crossfade overlaps; alignment across heterogeneous sources (mono mp3 + stereo flac); cache-key stability; golden graphs.
- Estimated ~300 LOC.
