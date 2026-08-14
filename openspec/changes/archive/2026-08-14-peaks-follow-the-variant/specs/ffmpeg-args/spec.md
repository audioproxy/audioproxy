## ADDED Requirements

### Requirement: The builder is given the source's own properties
The command builder SHALL receive the resolved source's sample rate and bit depth alongside its type, supplied from the probe the render already runs, so the options documented as following the source can do so. The builder itself SHALL still run no probe and read no bytes: the properties arrive as explicit arguments, each with a documented fallback.

#### Scenario: A lossless variant follows the source's depth
- **WHEN** a lossless format is requested with no `bd` and the probe reported the source's bit depth
- **THEN** the argv encodes at that depth rather than at the 16-bit fallback

#### Scenario: The fallbacks stay documented
- **WHEN** no probe metadata is available for a render
- **THEN** the argv falls back to 16-bit and 48 kHz, the same values it uses today

## MODIFIED Requirements

### Requirement: Options map to correct ffmpeg arguments
The system SHALL map each processing option to its ffmpeg form per API doc §3: trims as input-side `-ss`/`-t`, fades inside the trimmed region, `norm` as single-pass `loudnorm` (default `I=-16:TP=-1.5:LRA=11`), `sr` via `aresample`, `ch` via downmix, `br` as `-b:a`, `q` as the quality knob the codec actually exposes, and the MP4 family as fragmented MP4 cut on duration.

#### Scenario: Preview example
- **WHEN** building `f:opus/br:96/t:12.5:30/fade:0.5:1`
- **THEN** argv seeks to 12.5s before input, limits to 30s, applies `afade` in 0.5s/out 1s relative to the trimmed region, encodes libopus at 96k to an Ogg container on stdout

#### Scenario: Fragmented MP4
- **WHEN** building `f:m4a`
- **THEN** argv fragments on duration (`-movflags empty_moov+default_base_moof` with `-frag_duration`), so output is emitted progressively rather than flushed at EOF, and no seekable output is required
- **AND** argv does NOT use `frag_keyframe`, which cuts at video keyframes and therefore never fires on an audio-only stream

#### Scenario: Signed zero
- **WHEN** an option is spelled `-0` (`gain:-0`, `fade:-0`, `t:-0`)
- **THEN** it builds the identical argv to the same option spelled `0`, because the two normalize identically and so share a cache key

#### Scenario: Lossless bit depth follows the source
- **WHEN** building a lossless format with no `bd` and the source's bit depth is known
- **THEN** argv encodes at the source's depth, as `sr` defaults to the source's rate; with the depth unknown it falls back to 16-bit

#### Scenario: Filter order
- **WHEN** `norm`, `gain`, `sr` and `fade` are all present
- **THEN** the filtergraph runs `loudnorm` before `volume` (normalize, then offset), `aresample` after `loudnorm` (which outputs 192 kHz), and `afade` last

#### Scenario: Loudness normalization without an explicit sample rate
- **WHEN** building `norm:ebu` with no `sr` for a source whose rate the probe reported
- **THEN** argv appends an `aresample` to **the source's own rate**, since single-pass `loudnorm` would otherwise emit 192 kHz and §3.1 defines an absent `sr` as the source's rate

#### Scenario: A high-rate master is not silently downsampled
- **WHEN** building `norm:ebu` with no `sr` for a 96 kHz source
- **THEN** argv resamples to 96000, for a lossy format as well as a lossless one, because the §3.1 lossy ceiling bounds what a request may ask for rather than what a source may be — clamping here would let a loudness option change a variant's rate

#### Scenario: The ceiling still bounds an explicit request
- **WHEN** `sr:96000` is requested with a lossy format
- **THEN** the request is refused with `422`, unchanged by the scenario above

#### Scenario: A normalized render with no probed rate
- **WHEN** building `norm:ebu` with no `sr` and no source rate available
- **THEN** argv falls back to `aresample=48000`, the value it emitted unconditionally before the probe reached the builder

#### Scenario: Quality maps to the knob the codec has
- **WHEN** building `q` for mp3, ogg, aac or m4a
- **THEN** argv uses `-q:a`; for opus and flac it uses `-compression_level`

#### Scenario: Peaks extract raw PCM
- **WHEN** building `f:peaks`
- **THEN** argv decodes to interleaved `s16le` on stdout, honouring every option that changes the samples — `t`, `ch`, `fade`, `enhance`, `gain` and `norm` — and encoding nothing

#### Scenario: Peaks name their channel count explicitly
- **WHEN** building `f:peaks` with no `ch`
- **THEN** argv emits `-ac 1` rather than following the source, since the reducer must know the interleaving before it reads a byte; every other format omits `-ac` entirely when `ch` is absent
