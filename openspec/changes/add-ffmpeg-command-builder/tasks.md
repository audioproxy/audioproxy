## 1. Command builder

- [ ] 1.1 `AudioProxy.Ffmpeg.Command.build(options, input_url)` → argv list; baseline flags, input seek (`-ss`/`-t` before `-i`)
- [ ] 1.2 Filtergraph assembly: `afade` (in/out inside trim), `volume` (gain dB), `loudnorm` single-pass with `I/TP/LRA`, `aresample`, downmix (`-ac`)
- [ ] 1.3 Per-format output: codec + `-f` muxer table, `br` → `-b:a`, `q` → codec VBR flag, `bd` → PCM/flac sample format, fragmented MP4 flags
- [ ] 1.4 `AudioProxy.Ffmpeg.Command.content_type(format)` MIME mapping

## 2. Tests

- [ ] 2.1 Unit: exact argv snapshots for representative option sets (preview example from API doc §1, each format, each filter)
- [ ] 2.2 Injection: hostile URLs and `dl` names never alter argv shape; filtergraph contains only numeric renderings (regex assertion)
- [ ] 2.3 Property (StreamData, closes the round-trip): for random valid options, permuted option strings ⇒ identical argv; argv identical ⟺ cache key identical
- [ ] 2.4 Property: argv never contains empty strings, `nil`, or shell metacharacter interpretation points (always a flat list)

## 3. Docs

- [ ] 3.1 Update README: option → ffmpeg mapping table, pinned-ffmpeg note
