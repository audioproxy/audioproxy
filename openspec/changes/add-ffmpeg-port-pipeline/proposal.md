## Why

The heart of the system: run ffmpeg as a supervised subprocess, stream its stdout as chunks, and guarantee no orphan processes on client disconnect, timeout, or crash (CLAUDE.md conventions). Everything downstream (coalescing, HTTP delivery, write-back) consumes this chunk stream.

## What Changes

- Port wrapper GenServer: spawn ffmpeg from an argv list, own its lifecycle, emit stdout as chunk messages to a consumer.
- Bounded-buffer accounting per CLAUDE.md backpressure decision (raw Port first; FIFO escalation documented, not built).
- Enforce `AP_RENDER_TIMEOUT` (kill → timeout error) and kill-on-consumer-down (no orphans).
- Capture stderr (bounded) + exit status for error classification: decode failure (→ 415) vs source unreadable (→ 404) vs other (→ 502/504 semantics decided at HTTP layer).
- Integration test harness: fake subprocess script + real-ffmpeg tagged tests with generated fixtures.

## Capabilities

### New Capabilities

- `render-pipeline`: Subprocess lifecycle management, chunked output streaming, timeout/kill guarantees, and render-failure classification.

### Modified Capabilities

<!-- none -->

## Impact

- New: `lib/audio_proxy/ffmpeg/render.ex` (+ DynamicSupervisor), `test/support/fake_cmd.sh`, audio fixtures generated at test time.
- Depends on: `add-ffmpeg-command-builder` (argv), `init-project-scaffold`.
- Blocks: `add-render-coalescing`, `add-render-endpoint`, `add-peaks-format`, `add-info-endpoint` (shares subprocess plumbing).
