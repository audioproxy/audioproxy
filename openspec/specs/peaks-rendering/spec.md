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
JSON and `.dat`, adopted outright so peaks.js and that ecosystem read the
response as it comes off the wire. Because bucket boundaries are a function of
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
The system SHALL serve `pk_fmt:json` (default) as an audiowaveform-compatible JSON object: `version`, `channels`, `sample_rate`, `samples_per_pixel`, `bits`, `length`, and interleaved min/max integer `data`. `bits` SHALL always be 16.

#### Scenario: Schema shape
- **WHEN** a JSON peaks response is decoded
- **THEN** all listed fields are present, `length == pts`, and `data` holds `length × 2 × channels` integers within the signed 16-bit range

### Requirement: Binary peaks output
The system SHALL serve `pk_fmt:dat` as the compact binary format: audiowaveform's version-2 `.dat` layout, a little-endian header of version, flags, sample rate, samples-per-pixel, length and channel count, followed by `int16` min/max pairs.

The 8-bit variant the format permits SHALL NOT be offered: it would be a second cache key for a coarser picture of the same audio.

#### Scenario: Round-trip consistency
- **WHEN** the same variant is rendered as `json` and `dat`
- **THEN** decoding the binary yields the same pair values as the JSON `data`, and the header fields match their JSON counterparts

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

