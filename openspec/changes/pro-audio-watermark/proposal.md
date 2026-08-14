# PRO: Audible Watermarks

## Why

Time-boxed preview links (`exp`, shipped in 0.6.0) answer *how long* a screener lives; an audible watermark answers *who leaks it hurts*: a periodic stamp mixed over preview audio makes a captured stream traceable and unattractive to redistribute. Press screeners and pre-release review links are the concrete shape. Unlike mixing, the stamp is **operator content, not URL content**: the URL must never be able to inject an arbitrary overlay source, so no payload is involved at all.

## What Changes

- Operator config: the stamp source (a normal source URI, resolved through existing source types at boot-checkable validity) and its identity. Suggested vars: `AP_WM_SRC`, optional `AP_WM_GAIN` default.
- URL options (flat, no payload): `wm:<interval-seconds>` enables the stamp every N seconds; optional `wm_gain:<dB>`.
- **The stamp's content participates in the cache key** (a content hash or operator-set version captured at boot): swapping the stamp file must not serve stale watermarks from cache.
- Render: the stamp is fetched once per render via its source type, overlaid at the interval through the same filter machinery as mixing; one process, one slot.
- Composes with `exp` deliberately - the screener story is both together.

## Non-goals

- Steganographic/inaudible watermarking (different discipline entirely); per-request stamp text/TTS synthesis (names a future change if a customer needs per-recipient stamps).

## Capabilities

### New Capabilities
- `pro-audio-watermark`: operator-configured periodic stamp overlay - config, options, cache-key identity, filter integration.

### Modified Capabilities
<!-- none -->

## Impact

- Shares the overlay filter machinery with `pro-audio-mix` (soft dependency: whichever lands first builds it; sequencing after mix is natural).
- Tests: stamp presence at intervals in rendered output; cache-key changes when the stamp content changes; boot abort on unresolvable stamp source; `wm:` without configured stamp is the not-configured error.
- Estimated ~250 LOC.
