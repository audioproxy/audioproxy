## MODIFIED Requirements

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
