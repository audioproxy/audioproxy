## Why

Every render is an ffmpeg invocation whose arguments must be a pure, injection-safe function of the normalized options (CLAUDE.md conventions). Building this as its own slice completes the parse → normalize → cache key → argv round-trip and lets it be property-tested with no processes or I/O involved.

## What Changes

- Translate a normalized `%Options{}` + input URL into an ffmpeg argv list (no shell, ever).
- Input side: `-ss`/`-t` before `-i` for seek efficiency against HTTP(S) inputs.
- Filters: `afade` (inside trim), `volume` (gain), `loudnorm` single-pass (norm), `aresample` (sr), channel downmix (ch).
- Output side per format: mp3, Ogg/Opus, Ogg/Vorbis, ADTS AAC, fragmented MP4 (`-movflags frag_keyframe+empty_moov`), flac, wav — all writing to stdout (`pipe:1`).
- Content-Type mapping per format.

## Capabilities

### New Capabilities

- `ffmpeg-args`: Deterministic, injection-safe construction of ffmpeg argument vectors from normalized options.

### Modified Capabilities

- `processing-options`: reject the encoding and fade combinations that no ffmpeg invocation can honour.

## Impact

- New: `lib/audio_proxy/ffmpeg/command.ex`.
- Modified: `AudioProxy.Options` gains four rules the argv table exposed (`br` needs a lossy format, `q` a format with a quality scale, `bd:32f` needs `f:wav`, a fade-out needs a bounded trim), plus a public `render_number/1` so options strings and filter values render identically.
- Modified: `AudioProxy.OptionError` gains three reasons for those rules.
- Test generators lifted into `test/support/options_generators.ex`, shared by both property suites.
- Depends on: `add-options-parser`.
- Blocks: `add-ffmpeg-port-pipeline` (consumes argv), `add-peaks-format` (PCM extraction args).
