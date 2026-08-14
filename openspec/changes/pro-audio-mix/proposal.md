# PRO: Audio Mixing

## Why

Background music beds under speech are the most-requested composition feature (Cloudinary exposes layered overlays with static per-layer volume for exactly this; its accessibility guidance mixes narration over beds at fixed dB offsets). audioproxy can do one better than static gain staging: real sidechain ducking, where the bed dips under the voice and swells back in the gaps - a stock ffmpeg filter, not new machinery. The single-source URL grammar cannot express this; the payload envelope (`pro-request-payloads`) can.

## What Changes

- A `mix:{payload}` variant option whose payload is an ordered track list: `[{src}, {src, at, gain, loop, duck}, ...]`. First track is the program; subsequent tracks are overlays with start offset seconds (`at`), dB gain (`gain`), looping to program length (`loop`), and `duck: true` to sidechain-compress against the program.
- **Variant-defining**: the canonical payload participates in the cache key. One composition is one variant; coalescing, write-back, HIT semantics unchanged.
- Render: all sources resolve through the existing source types (each authorized against the allowlist, each probed under the probe pool); one ffmpeg process, one filter graph (`adelay`, `volume`, `aloop`, `sidechaincompress`, `amix`); one semaphore slot.
- Bounds: track count capped (default 4); per-track fields validated with the same numeric-bounds discipline as flat options.
- Composes with everything downstream: the mixed program is then subject to `f:`, `br:`, `t:`, `fade:`, `norm:`, `enhance:` exactly as a single source would be.

## Non-goals

- Concatenation (`pro-audio-stitch`), audible watermarks (`pro-audio-watermark`), per-track time-stretching or pitch. Video program tracks wait for `pro-video-sources`.

## Capabilities

### New Capabilities
- `pro-audio-mix`: multi-track composition via signed payload - track schema, ducking, cache-key participation, resolution and bounds.

### Modified Capabilities
<!-- none -->

## Impact

- Depends on: `pro-request-payloads`. New (PRO tree): track schema validation, filter-graph builder (argv only, injection-safe), N-source resolution orchestration.
- Tests: golden filter graphs per track combination; cache-key stability across payload spellings; a rendered mix asserted for duck behavior (RMS of the bed drops under speech); allowlist enforcement per track.
- Estimated ~450 LOC; the filter-graph builder is the bulk.
