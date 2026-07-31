## 1. Command builder

- [x] 1.1 `AudioProxy.Ffmpeg.Command.build(options, input_url)` → argv list; baseline flags, input seek (`-ss`/`-t` before `-i`)
- [x] 1.2 Filtergraph assembly: `afade` (in/out inside trim), `volume` (gain dB), `loudnorm` single-pass with `I/TP/LRA`, `aresample`, downmix (`-ac`)
- [x] 1.3 Per-format output: codec + `-f` muxer table, `br` → `-b:a`, `q` → codec VBR flag, `bd` → PCM/flac sample format, fragmented MP4 flags
- [x] 1.4 `AudioProxy.Ffmpeg.Command.content_type(format)` MIME mapping

## 2. Options rules the argv table exposed

Building the table surfaced four accepted-but-unrenderable combinations. Each
is refused at parse time for the same reason the peaks rule exists: an option
that cannot change the output would give byte-identical output two cache keys.

- [x] 2.1 `br` requires a lossy format; `q` requires a format whose encoder has a quality scale (not `wav`)
- [x] 2.2 `bd:32f` requires `f:wav` — the flac encoder takes `s16`/`s32` only
- [x] 2.3 A fade-out requires a bounded trim; its start is `duration - out`, and probing for a duration is out of scope for a pure builder
- [x] 2.4 New `OptionError` reasons, and `Options.render_number/1` made public so options strings and filter values render identically

## 3. Tests

- [x] 3.1 Unit: exact argv snapshots for representative option sets (preview example from API doc §1, each format, each filter)
- [x] 3.2 Injection: hostile URLs and `dl` names never alter argv shape; filtergraph contains only numeric renderings (regex assertion)
- [x] 3.3 Property (StreamData, closes the round-trip): for random valid options, permuted option strings ⇒ identical argv; equal cache keys ⇒ identical argv
- [x] 3.4 Property: argv never contains empty strings, `nil`, or shell metacharacter interpretation points (always a flat list)
- [x] 3.5 Generators lifted into `AudioProxy.OptionsGenerators` so both property suites probe one grammar
- [x] 3.6 `:ffmpeg`-tagged: every format, every filter and the §1 preview run through the real binary

## 4. Docs

- [x] 4.1 Update README: option → ffmpeg mapping table, filter-order rationale, the `norm` → 48 kHz consequence, pinned-ffmpeg note
- [x] 4.2 Spec delta for the four new options rules (`specs/processing-options/spec.md`)

## 5. Adversarial review (round 1)

Self-review plus an external pass via `opencode run -m openrouter/moonshotai/kimi-k2.7-code`.
Log kept at `second-opinion.md` until attestation.

- [x] 5.1 (H) `-0` collapsed at parse time — `fade:-0` and `fade:0` shared a cache key and built different commands, verified as different output bytes
- [x] 5.2 (H) `f:m4a` fragments on duration; `frag_keyframe` never fires on audio, so the whole render was flushed at EOF (19.7 s to first byte on a 20 s source)
- [x] 5.3 (H) `q` bounded per codec — `f:flac/q:13` is refused by ffmpeg, so it was a 500 where every other bad value is a 422
- [x] 5.4 (M) `validate_bit_depth_format/1` defers to the peaks rule like its siblings
- [x] 5.5 (M) ffmpeg test helper uses `binary_slice/3`; `binary_part/3` raised on any diagnostic under 400 bytes, i.e. whenever a render actually failed
- [x] 5.6 (M) replaced the vacuous "equal cache keys imply identical argv" property, which guarded on a collision that never happened
- [x] 5.7 (M) `build/3` takes the source's bit depth so lossless output follows it, as `sr` follows the source rate
- [x] 5.8 (L) generators emit `-0`; regression tests and a property cover it
- [x] 5.9 Docs: API doc §3.1 and CLAUDE.md corrected on m4a fragmentation, `q` ranges and the `bd` default
