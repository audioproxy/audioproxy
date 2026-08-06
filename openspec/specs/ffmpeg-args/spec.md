# ffmpeg-args Specification

## Purpose
Every render is one ffmpeg invocation, and its arguments are a pure function of
the normalized options plus the input URL. That purity is what closes the loop
the proxy is built on: parse → normalize → cache key → identical ffmpeg args.
Equal cache keys must imply byte-identical commands, because a cache hit is a
claim that the stored bytes are the bytes that were asked for — and the key
only knows about the options string. Any distinction the argv preserves but
normalization collapses turns that claim into a lie.

The consequences run in both directions. An option that reaches the encoder
unbounded becomes a render failure where every other bad value is a 422, and an
option the encoder ignores becomes two cache entries for one file. So the
argument table is not merely a translation layer: it is where the option
grammar is proved renderable, and rules discovered here belong back in the
options layer rather than being absorbed silently.

Construction is argv-only. There is no shell anywhere in this path, so a source
URL carrying shell metacharacters is one element of a list and stays data.
The filtergraph is the single place values are concatenated into one argument,
and only validated numbers ever reach it.

The builder deliberately knows nothing it cannot derive from the options and
the source's own properties — it runs no probe and reads no bytes. Where a
decision genuinely needs the source (a lossless default bit depth, the input
protocol set), the source metadata is an explicit argument with a documented
fallback or no fallback at all, never an implicit dependency.

Two things appear in every argv regardless of the options, and neither is
derivable from the URL: the non-audio streams are disabled, and ffmpeg's input
protocols are restricted to what the resolved source actually needs. Both are
defence in depth behind the `audio-only-policy` gate rather than the policy
itself — they are what still holds if that gate is bypassed, reordered, or
handed a source it cannot see inside. Their *placement* is load-bearing in a way
that is easy to lose in a refactor: the whitelist precedes `-i` so it binds the
input format context, and the disable flags follow it so they bind the output.

The flag vocabulary is published rather than implicit, because "no URL content
can become an ffmpeg flag" is only worth stating if something checks it. What
makes the check possible is knowing which flags take a value: a bare leading
hyphen cannot distinguish the flag `-t` from the *value* `-1` that `f:ogg/q:-1`
legitimately renders, so a check built on that distinction alone would have to
be loosened until it caught nothing.

## Requirements

### Requirement: Argv is a pure function of normalized options
The system SHALL build the ffmpeg argument vector deterministically from the normalized options and input URL, such that equal normalized options always produce identical argv lists.

#### Scenario: Round-trip determinism
- **WHEN** two equivalent option strings (different order/spelling) are parsed and normalized
- **THEN** both produce byte-identical argv lists

#### Scenario: Stdout output
- **WHEN** any audio format is requested
- **THEN** the argv ends writing to `pipe:1` with an explicit `-f` muxer matching the requested format

### Requirement: Argument construction is injection-safe
The system SHALL construct arguments exclusively as argv lists; no shell interpretation, and user-controlled values (source URL, `dl` filename) SHALL never be interpolated into a shell string or filter expression unescaped.

#### Scenario: Hostile source URL
- **WHEN** the input URL contains shell metacharacters (`;`, `$(`, quotes, spaces)
- **THEN** the argv list contains it as a single argument and no shell is involved

#### Scenario: Filter values are numeric only
- **WHEN** trim/fade/gain/norm options are rendered into filter strings
- **THEN** only validated numeric renderings appear in the filter expression

#### Scenario: Opaque options stay out of the command
- **WHEN** `dl` or `cb` are present
- **THEN** the argv is identical to the same request without them — neither describes the render

#### Scenario: Argv elements are complete arguments
- **WHEN** building any valid options
- **THEN** the argv is a flat list of non-empty binaries, so no element can be split or dropped by the exec layer

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
- **WHEN** building `norm:ebu` with no `sr`
- **THEN** argv appends `aresample=48000`, since single-pass `loudnorm` would otherwise emit 192 kHz

#### Scenario: Quality maps to the knob the codec has
- **WHEN** building `q` for mp3, ogg, aac or m4a
- **THEN** argv uses `-q:a`; for opus and flac it uses `-compression_level`

#### Scenario: Peaks extract raw PCM
- **WHEN** building `f:peaks`
- **THEN** argv decodes to interleaved `s16le` on stdout, honouring `t`, `ch` and `fade` and encoding nothing

#### Scenario: Peaks name their channel count explicitly
- **WHEN** building `f:peaks` with no `ch`
- **THEN** argv emits `-ac 1` rather than following the source, since the reducer must know the interleaving before it reads a byte; every other format omits `-ac` entirely when `ch` is absent

### Requirement: Non-audio streams are disabled in every argv
The command builder SHALL include `-vn`, `-sn`, and `-dn` in every render argument vector (audio and peaks modes alike), regardless of options, so no video, subtitle, or data stream can ever be decoded, filtered, or encoded.

#### Scenario: Flags present for every format
- **WHEN** argv is built for each supported output format and for PCM/peaks extraction
- **THEN** `-vn`, `-sn`, and `-dn` are present in each

#### Scenario: The flags bind the output
- **WHEN** any argv is built
- **THEN** the three flags appear *after* `-i`, where ffmpeg reads them as output options; before it they would be input options with different meaning

#### Scenario: No video encoder or filter is reachable
- **WHEN** argv is built for every supported format with every filter option present
- **THEN** no video codec, video filter or stream-mapping token appears

### Requirement: Input protocol whitelist in every argv
The command builder SHALL include `-protocol_whitelist` before the input in every argument vector, with the minimal set for the **resolved source's type**: `file` for local sources; `https,tls,tcp` for HTTPS sources; the same for S3 sources, plus `http` only where a cleartext `AP_S3_ENDPOINT` is configured, since a presigned URL carries its endpoint's scheme.

The set SHALL be derived from the source type and never from the input string, a processing option, or a dedicated environment variable — a knob would reopen what this closes. A source type with no protocol set SHALL raise rather than inherit one.

#### Scenario: Whitelist precedes input
- **WHEN** any argv is built
- **THEN** `-protocol_whitelist` appears as an input option (before `-i`) with the source type's set

#### Scenario: Local sources cannot reach the network
- **WHEN** argv is built for a local source
- **THEN** the whitelist is exactly `file` — no network protocol is available to the invocation

#### Scenario: Remote sources cannot reach the filesystem
- **WHEN** argv is built for an HTTPS or S3 source
- **THEN** the whitelist contains no `file` entry, whatever the configured endpoint

#### Scenario: A cleartext development endpoint is the one widening
- **WHEN** argv is built for an S3 source and `AP_S3_ENDPOINT` names an `http://` endpoint
- **THEN** the whitelist gains `http` and nothing else, because every presigned URL that deployment mints is cleartext

#### Scenario: The source type is required
- **WHEN** an argv is built without a resolved source type
- **THEN** it raises rather than defaulting, since a default would guess which side of the network/filesystem boundary the render sits on

### Requirement: Flag allowlist is introspectable
The command builder SHALL expose the complete set of flags it can ever emit, and for each whether it is followed by a value, so the argv-allowlist property test compares against a published set rather than a hardcoded copy.

#### Scenario: Allowlist covers reality
- **WHEN** argv is built for randomly generated valid options (property test)
- **THEN** every token in a flag position is a member of the published allowlist

#### Scenario: The allowlist excludes non-audio flags
- **WHEN** the published set is inspected
- **THEN** it contains no video codec, video filter, or stream-mapping flag

#### Scenario: A value is not mistaken for a flag
- **WHEN** an option renders a negative value (`f:ogg/q:-1` emits `["-q:a", "-1"]`)
- **THEN** the value is recognized as the argument to its flag rather than reported as an unknown flag

### Requirement: Content-Type mapping
The system SHALL expose the correct Content-Type for every output format (e.g., `audio/mpeg`, `audio/ogg`, `audio/aac`, `audio/mp4`, `audio/flac`, `audio/wav`).

#### Scenario: Every format has a type
- **WHEN** iterating all supported formats
- **THEN** each maps to a non-empty, correct MIME type
