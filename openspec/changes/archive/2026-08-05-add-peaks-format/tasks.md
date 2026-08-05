## 1. Command builder extension

- [x] 1.1 PCM extraction mode in `Ffmpeg.Command`: `-f s16le` to stdout, trim/downmix honored, encoding options excluded; argv snapshot + property tests extended

## 2. Peaks reduction

- [x] 2.1 Streaming min/max reducer over s16le chunks with bucket boundaries from probed duration; partial-final-bucket handling; odd-byte chunk seams handled (sample straddling chunk boundary)
- [x] 2.2 JSON serializer (audiowaveform schema: version/channels/sample_rate/samples_per_pixel/bits/length/data)
- [x] 2.3 `.dat` serializer (LE header + int16 pairs)
- [x] 2.4 Unit tests: synthetic PCM (constructed binaries — ramp, alternating extremes, silence) → exact expected pairs; chunk-seam property test (random chunking ⇒ identical result)

## 3. Endpoint integration

- [x] 3.1 Peaks renderer as alternative coordinator pipeline; Content-Type mapping; defaults (`pts:800`, mono, `pk_fmt:json`)
- [x] 3.2 Integration (`@tag :ffmpeg`): sine/silence/trim scenarios from spec; json↔dat value equality; peaks HIT via variant cache

## 4. Docs

- [x] 4.1 Update README + CLAUDE.md open questions: peaks schema decision (audiowaveform-compatible), usage examples with peaks.js
