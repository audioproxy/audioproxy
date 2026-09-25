# peaks-rendering Specification

## Purpose
Serve waveform min/max data so a player UI can draw a shape without decoding
audio in the browser. `f:peaks` is a *format*, not a separate resource: the
same URL grammar, signature gate, cache key, coalescing and write-back as any
audio variant, differing only in who produces the bytes. ffmpeg decodes the
source to raw interleaved `s16le` and the proxy reduces those samples to `pts`
min/max pairs, so the PCM — tens of megabytes for a long source — is folded
chunk by chunk and dropped rather than retained.

The wire formats are [audiowaveform](https://github.com/bbc/audiowaveform)'s
JSON and `.dat`, adopted outright so that ecosystem reads the response as it
comes off the wire. peaks.js reads only the 8-bit form, which `pk_bits:8`
selects. Because bucket boundaries are a function of
the total sample count, a peaks render is a leading `ffprobe` *and then* a
decode; it shares `source-info`'s probe argv and contract mapping, so the
duration the proxy reports and the duration it buckets by cannot drift.
## Requirements
### Requirement: Peaks are computed from decoded audio
The system SHALL reduce `f:peaks` from the decoded samples of the variant the same URL would render, so every option that changes those samples — `t`, `ch`, `fade`, `enhance`, `gain` and `norm` — is reflected in the picture, and only options that cannot change it (`br`, `q`, `bd`, `sr`) are refused.

#### Scenario: A level change moves the picture
- **WHEN** `f:peaks/gain:-6` is requested
- **THEN** the pairs are drawn from the attenuated samples, so a waveform matches the audio the same options would render

#### Scenario: A normalized render draws a normalized waveform
- **WHEN** `f:peaks/norm:ebu` is requested
- **THEN** loudness normalization applies to the decode the reduction reads

#### Scenario: Bucket boundaries survive the loudness stage
- **WHEN** a peaks render includes a filter chain that would otherwise change the decode's sample rate
- **THEN** the frames the decode emits match the count the reduction budgeted from the source probe, so no part of the audio is folded into the final bucket and the reported `sample_rate` describes the samples actually reduced

#### Scenario: Encoding options remain refused
- **WHEN** `br`, `q`, `bd` or `sr` is combined with `f:peaks`
- **THEN** the request is refused with `422` naming the segment, because an option that cannot change the picture would hand one result two cache keys

### Requirement: JSON peaks output
The system SHALL serve `pk_fmt:json` (default) as an audiowaveform-compatible JSON object: `version`, `channels`, `sample_rate`, `samples_per_pixel`, `bits`, `length`, and interleaved min/max integer `data`. `bits` SHALL report the value of `pk_bits`, which defaults to 16.

#### Scenario: Schema shape
- **WHEN** a JSON peaks response is decoded
- **THEN** all listed fields are present, `length == pts`, and `data` holds `length × 2 × channels` integers within the signed range named by `bits`

#### Scenario: Eight-bit values are reported as such
- **WHEN** `f:peaks/pk_bits:8` is requested
- **THEN** the object reports `bits: 8` and every value in `data` lies within −128..127, so a reader that validates the field against the data is not lied to

### Requirement: Binary peaks output
The system SHALL serve `pk_fmt:dat` as the compact binary format: audiowaveform's version-2 `.dat` layout, a little-endian header of version, flags, sample rate, samples-per-pixel, length and channel count, followed by min/max pairs whose width follows `pk_bits` — `int16` by default, `int8` under `pk_bits:8`.

The header's flags field SHALL carry the width the way audiowaveform's own format does, so a reader that already handles both widths needs no out-of-band knowledge of which one it was given.

#### Scenario: Round-trip consistency
- **WHEN** the same variant is rendered as `json` and `dat`
- **THEN** decoding the binary yields the same pair values as the JSON `data`, and the header fields match their JSON counterparts

#### Scenario: Eight-bit binary is half the payload
- **WHEN** the same `pts` and `ch` are rendered as `pk_bits:16` and `pk_bits:8` in `dat`
- **THEN** both carry a 24-byte header that differs only in the flags field (1 for 8-bit, 0 for 16-bit), and the 8-bit body is exactly half the size of the 16-bit body

#### Scenario: The narrower picture is a reduction of the wider one
- **WHEN** the same variant is rendered at both widths
- **THEN** each 8-bit value equals its 16-bit counterpart scaled down by 256 and clamped to the signed 8-bit range, so the two are the same waveform at two resolutions rather than two independent reductions

### Requirement: A source no waveform can be drawn from is refused
The system SHALL answer **415** when the probe succeeds but describes something unpeakable — a source with no audio stream, or one whose duration cannot be determined — rather than reporting a server failure for a condition that is permanent and belongs to the source.

A probe the system cannot *read* is a different case and remains a server failure (500): it says nothing about the source.

#### Scenario: No audio stream
- **WHEN** peaks are requested for a source carrying no audio stream
- **THEN** the response is `415` with error `undecodable_source`

### Requirement: Peaks participate in caching
The system SHALL cache peaks variants exactly like audio variants (cache key, write-back, HIT redirect) with `Content-Type: application/json` or `application/octet-stream`.

#### Scenario: Peaks HIT
- **WHEN** the same peaks URL is requested twice with the variant bucket configured
- **THEN** the second response is a HIT without decoding

