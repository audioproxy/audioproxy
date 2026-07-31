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
- **Filter order is `loudnorm → volume → aresample → afade`**, and each position is load-bearing: normalizing *after* a static gain would undo it, so `gain` with `norm` means "normalize, then offset"; `aresample` must follow `loudnorm` because single-pass loudnorm emits 192 kHz; `afade` goes last so the fade shape survives the stages above it.
- **`norm` without `sr` appends `aresample=48000`.** Consequence of the above: without it every normalized render would be 192 kHz. 48 kHz is the API's own lossy ceiling (§3.1), but it does mean `norm` downsamples a 96 kHz master. Choosing better needs the source's real rate, which a pure function of the options cannot have — an explicit `sr` overrides.
- **Four options rules move up into `AudioProxy.Options`**, discovered while building the table: `br` on a lossless format and `q` on PCM are accepted by ffmpeg and ignored; `bd:32f` on flac fails inside ffmpeg; a fade-out has no start without a bounded trim. Rejecting at parse time is the established policy (the peaks rule) — an option that cannot change the output would otherwise buy a second cache key for identical bytes. Recorded as a MODIFIED requirement in `specs/processing-options/spec.md`.

## Risks / Trade-offs

- [ffmpeg version drift changes behavior for same argv] → pin ffmpeg major in the runtime image (docker slice); the `:ffmpeg`-tagged suite runs every format and filter through the real binary, so a codec name a build does not carry fails a test rather than a request.
- [libopus encodes at 48/24/16/12/8 kHz only] → `sr:44100` with `f:opus` is renegotiated to 48 kHz by ffmpeg and yields the same bytes as `f:opus` alone under a different cache key. Costs a duplicate cache object, not a wrong render; tracked with the other semantic no-ops rather than adding a fifth validation rule.
- [Single-pass loudnorm is approximate] → documented API-level caveat (§3.2), not a code problem.
