## Why

Single-pass `loudnorm` is documented as approximate — good enough for previews, not for masters (a standing CLAUDE.md open question). Accurate normalization needs a measurement pass, and measurement is independently valuable: its numbers feed ordinary `gain:` options today, and they are the foundation for group/album normalization later (per-track offsets computed across a set, baked into pure render URLs). PRO scope: `pro-` prefixed for later extraction into a separate repo; it touches no other change.

## What Changes

- New signed endpoint `GET /{sig}/measure/{source}` (no processing options, like `info`): one full-decode `loudnorm` analysis pass over the source, returning measured loudness as JSON — `input_i` (LUFS), `input_tp` (dBTP), `input_lra` (LU), `input_thresh`, plus duration and the canonical source.
- Measurement is per-source, never per-variant: trimmed previews normalize against the full track's numbers — that is what makes a preview reel sound coherent.
- Runs under the render concurrency limit (a decode pass is render-class CPU work) and through the render coalescing machinery (concurrent measure requests for one source share one pass).
- HTTP-cacheable like `/info`: strong ETag from source identity + source ETag, `If-None-Match`/304.
- Out of scope, recorded: extending the `norm` option grammar to accept measured parameters (true two-pass render). Measurement results are consumable today via `gain:`; the grammar extension is a separate future change against the processing-options spec.

## Capabilities

### New Capabilities

- `pro-loudness-measurement`: The measurement endpoint, its response contract, caching, and resource semantics.

### Modified Capabilities

<!-- none — deliberately; extraction candidate -->

## Impact

- New: measure action + route; loudness argv addition to the command builder's vocabulary (additive — a new mode like peaks PCM, no existing mapping changes).
- Depends on (implementation order, no artifact amendments): merged core, `add-render-semaphore` (slot participation), `add-render-coalescing` (shared passes), `add-cdn-cache-discipline` (conditional-request machinery).
- Position: PRO track, after slice 16 (`add-variant-cache`); unscheduled relative to the OSS board.
