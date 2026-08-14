# Add Enhance Preset (enhance:voice)

## Why

Preview-grade speech benefits enormously from a boring chain: high-pass, denoise, de-ess, compress. Exposing the knobs would explode the URL grammar and fragment the cache; exposing nothing leaves every operator re-implementing the same ffmpeg incantation client-side, where it cannot cache. A named preset is the cache-honest middle: one option value, one pinned chain, one variant. OSS deliberately - it is the giveaway that makes the PRO tier (`pro-ml-denoise`'s `enhance:studio`) legible.

## What Changes

- `enhance:voice`: a curated conventional chain (high-pass, `afftdn`, de-esser, compressor; exact parameters implementation-pinned). Orthogonal to `norm:` (the preset does not normalize loudness; combining them is allowed and documented).
- **The pinning rule, stated as spec**: a preset value maps to an exact chain forever. Improving the chain mints a new value (`voice2`); the old value keeps producing the old bytes. Anything else silently changes bytes behind `Cache-Control: immutable`.
- Full ripple: options table, round-trip property, API doc, README, llms-full (option-table guard enforces).

## Capabilities

### New Capabilities
<!-- none -->

### Modified Capabilities
- `processing-options`: the `enhance` option, its value vocabulary, and the preset pinning rule.
- `ffmpeg-args`: the pinned voice chain and its filter order relative to trim/fade/gain/norm.

## Impact

- Modified: options parser/normalizer, command builder, docs per the docs-shape table.
- Tests: golden argv; round-trip; `enhance`+`norm` combination; an `:ffmpeg` render asserting the chain audibly alters a sibilant noisy fixture (spectral assertion, not golden bytes).
- Estimated ~250 LOC. No new dependencies; every filter is stock ffmpeg.
- Position: ready when picked up; `pro-ml-denoise` depends on it.
