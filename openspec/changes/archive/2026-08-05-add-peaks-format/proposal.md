## Why

Waveform peaks (`f:peaks`, API doc §3.3) power waveform UIs without client-side decoding. It is a format, not a separate resource: same URL grammar, same cache/coalescing machinery, different renderer — ffmpeg decodes to raw PCM, Elixir reduces to min/max pairs.

## What Changes

- `f:peaks` rendering: ffmpeg → raw PCM (respecting `t` and `ch`, ignoring encoding options per §3.3) → min/max pair reduction to `pts` buckets (default 800).
- Output codecs: `pk_fmt:json` (audiowaveform-compatible JSON, resolving the CLAUDE.md open question on the exact schema) and `pk_fmt:dat` (compact binary, audiowaveform .dat-compatible).
- Peaks flow through the normal cache-key/write-back/HIT machinery (small immutable objects).

## Capabilities

### New Capabilities

- `peaks-rendering`: PCM reduction to waveform peaks with JSON and binary output formats.

### Modified Capabilities

- `ffmpeg-args`: The command builder SHALL support a raw-PCM extraction mode (`s16le` to stdout, trim/channel options honored, encoding options ignored) used by the peaks renderer.

## Impact

- New: `lib/audio_proxy/peaks.ex`.
- Modified: command builder (PCM mode); options validation already gates `pts`/`pk_fmt` on `f:peaks`.
- Depends on: `add-render-endpoint` (delivery), `add-ffmpeg-port-pipeline`, `add-options-parser`.
