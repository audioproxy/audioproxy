## Context

Completes the CLAUDE.md round-trip invariant: parse → normalize → cache key → **identical ffmpeg args**. Pure function, no processes: `%Options{} + input_url → [String.t()]`.

## Goals / Non-Goals

**Goals:**
- Deterministic argv for every valid normalized options struct.
- Injection safety by construction.

**Non-Goals:**
- Running ffmpeg (that's `add-ffmpeg-port-pipeline`); peaks argv beyond raw PCM extraction (peaks slice extends this module).

## Decisions

- **Trim placement**: `-ss`/`-t` *before* `-i` (input seeking) so ffmpeg's HTTP client issues Range requests and never reads skipped bytes — this is the whole point of the presigned-URL input architecture. Fades are expressed relative to the trimmed region (t=0 after input seek), which input-side seeking gives us for free.
- **One filtergraph string** built from validated numeric renderings only: `afade`, `volume` (gain), `loudnorm`, `aresample`; downmix via `-ac`. User text never enters the filtergraph — `dl`/`cb`/source never touch argv except the input URL as a standalone argv element.
- **Explicit `-f` muxer always** (stdout has no filename to infer from): `mp3`, `ogg` (opus/vorbis), `adts`, `mp4` + fragflags, `flac`, `wav`.
- **Codec table** per format: `libmp3lame`, `libopus`, `libvorbis`, `aac`, `flac`, `pcm_s16le/s24le/f32le` (from `bd`).
- **`-nostdin -hide_banner -loglevel error`** always; stderr reserved for error diagnosis by the pipeline slice.
- **Baseline flags stable**: never reorder or add args conditionally on anything outside the normalized options — argv list equality is the tested contract.

## Risks / Trade-offs

- [ffmpeg version drift changes behavior for same argv] → pin ffmpeg major in the runtime image (docker slice); argv contract tested against the pinned version in integration tests.
- [Single-pass loudnorm is approximate] → documented API-level caveat (§3.2), not a code problem.
