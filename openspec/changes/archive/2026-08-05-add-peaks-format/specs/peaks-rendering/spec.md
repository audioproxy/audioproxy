## ADDED Requirements

### Requirement: Peaks are computed from decoded audio
The system SHALL render `f:peaks` by decoding the source (respecting the `t` trim, ignoring encoding options) and reducing samples to `pts` min/max pairs (default 800) spanning the selected region evenly.

`ch` selects the channel count and, unlike every other format, SHALL default to **mono** rather than following the source: the reducer must know the interleaving before it reads a byte, and a waveform UI draws one shape. That default SHALL be materialized into the normalized options string, so `f:peaks` and `f:peaks/ch:1` are one cache key.

`length` SHALL equal `pts` exactly, whatever sample count the decoder produced.

#### Scenario: Known signal shape
- **WHEN** peaks are rendered for a generated full-scale sine
- **THEN** min and max values approach the signed 16-bit bounds uniformly across buckets (within codec tolerance)

#### Scenario: Silence detected
- **WHEN** peaks are rendered for a silent region
- **THEN** the corresponding pairs are ~0

#### Scenario: Trim respected
- **WHEN** peaks are rendered with `t:1:1` over a fixture that is silent across that window
- **THEN** all pairs are ~0 even though the rest of the file is loud

#### Scenario: The mono default is one cache key
- **WHEN** `f:peaks` and `f:peaks/ch:1` are normalized
- **THEN** both yield the same options string, and `f:peaks/ch:2` yields a different one

#### Scenario: Encoding options ignored
- **WHEN** `br` or `sr` accompany `f:peaks`
- **THEN** options validation rejects the request (422) per §3.3's option gating

#### Scenario: Decoder disagrees with the probe
- **WHEN** the decode yields more or fewer samples than the probed duration implied
- **THEN** extra samples fold into the final pair, missing ones leave trailing pairs at zero, and `length` is still `pts`

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
