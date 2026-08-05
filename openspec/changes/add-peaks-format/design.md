## Context

ffmpeg does decode + trim + downmix (same presigned-URL input path); Elixir does the arithmetic. Resolves the CLAUDE.md open question: adopt audiowaveform's JSON/dat formats outright — the dominant waveform tooling ecosystem, nothing to invent.

## Goals / Non-Goals

**Goals:**
- Numerically predictable peaks; wire-compatible with audiowaveform consumers (peaks.js).

**Non-Goals:**
- Multi-resolution/zoom pyramids; server-side rendering of waveform images; eager peaks alongside audio variants (§3.3 notes it as future work).

## Decisions

- **PCM transport: `s16le` mono-or-stereo at source rate** — 16-bit matches audiowaveform `bits:16` output semantics directly; no float path needed.
- **Streaming reduction**: consume PCM chunks incrementally (binary pattern matching over `<<sample::little-signed-16>>`), maintaining current-bucket min/max — O(1) memory, no full-buffer PCM in RAM even for long sources.
- **Bucket boundaries from total sample count**, which requires knowing duration up front: take it from a leading ffprobe rather than buffering; `samples_per_pixel = ceil(region_samples / pts)`, last bucket may be partial. Duration drift between probe and decode handled by clamping (spec tolerance).
  - *Correction during implementation:* the ffprobe wrapper was **not** already built when this slice began — `/info` was a separate, unstarted change — so the slice first added a minimal `AudioProxy.Ffmpeg.Probe` of its own.
  - *Second correction, on rebase:* `/info` then landed first (PR #37) and brought `AudioProxy.Ffprobe`, a superset. The peaks-local wrapper was deleted; this slice now reuses `Ffprobe.args/1` and `Ffprobe.contract/2` and adds only the `args/1` seam, so a caller can spawn the subprocess itself. `/info` blocks on `Ffprobe.probe/2` because it is a request doing nothing else; `Peaks.Render` cannot, since it must stay answerable to `cancel/1` while the probe runs, so it spawns the same argv through `Ffmpeg.Render` and folds the chunks in `handle_info/2`. Sharing the mapping is what stops the duration `/info` *reports* from drifting from the one peaks *bucket by*.
- **`ch` defaults to 1 under `f:peaks`**, materialized into the cache key so `f:peaks` and `f:peaks/ch:1` are one variant. Every other format follows the source when `ch` is absent; the reducer cannot, because it has to know the interleaving before the first byte.
- **`bits: 16` always in v1**; `channels` follows `ch` (default: downmix to 1 for peaks — waveform UIs overwhelmingly want mono; spec'd via options default table, overridable with `ch:2`).
- **Renderer plugs into the coordinator as an alternative pipeline**: same consumer contract (chunks are the serialized output produced at end for `json`, streamed per-bucket for `dat`) — delivery/cache/coalescing code untouched.

## Risks / Trade-offs

- [Probe+decode = two subprocess invocations] → probes are cheap and header-only; alternative (buffer everything) costs memory instead — acceptable.
- [Codec decode tolerance vs exact assertions] → tests assert within tolerance bands (sine ±5 %, silence < 1 % of full scale) and use WAV fixtures for exactness where needed.
