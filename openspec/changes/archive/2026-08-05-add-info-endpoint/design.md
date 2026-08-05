## Context

ffprobe emits JSON natively; the work is contract filtering, cache headers, and reusing the subprocess plumbing (bounded, timed out, orphan-free) for a non-streaming command.

## Goals / Non-Goals

**Goals:**
- Stable §4 JSON contract regardless of ffprobe's verbose output shape; HTTP-cacheable.

**Non-Goals:**
- Server-side caching of probe results beyond conditional-request support (the client/CDN layer owns that; variants are the expensive thing, probes are cheap).

## Decisions

- **Collect-then-parse**: run ffprobe through the Port wrapper accumulating stdout (probes are small), `JSON.decode` (OTP 27 stdlib `:json` via Elixir wrapper — no jason dep), then map to the contract. Timeout: a probe-specific shorter timeout (probes read headers, not streams).
- **Field mapping table** `format/stream → contract` with explicit per-format quirks (bit_depth from `bits_per_raw_sample` falling back to `sample_fmt`; duration from format section, stream fallback); unknown/missing → omit key.
- **ETag = hash(canonical_source ‖ source_etag)** from the resolver + HEAD — changes when the object changes, stable otherwise; enables the §4 "immutable per source ETag" caching.
- **`info` detected in ParseOptions** as an exclusive pseudo-option: any other option present → 422 (one rule, spec'd).

## Risks / Trade-offs

- [ffprobe JSON field variance across formats/versions] → mapping table with fixture-driven tests per format (wav/mp3/flac/ogg); pinned ffmpeg version in runtime image.
- [Tags can be arbitrarily large/weird] → passthrough of string-valued format tags only, size-capped.
