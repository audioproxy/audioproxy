## MODIFIED Requirements

### Requirement: Invalid options are rejected with structured errors
The system SHALL reject unknown keys, out-of-domain values, and conflicting combinations with a structured error naming the offending segment; the HTTP layer maps these to 422.

This extends to combinations that no encoder can honour. Building the ffmpeg argv made three of them visible: `br` on a lossless format and `q` on PCM are accepted by ffmpeg and silently ignored, `bd:32f` on flac fails inside ffmpeg (its encoder takes `s16` and `s32` only), and a fade-out has no start time without a bounded trim to count back from. All four are refused at parse time — the same reasoning as the peaks rule below, since an option that cannot change the output would otherwise give byte-identical output two cache keys.

#### Scenario: Unknown key
- **WHEN** parsing `xyz:1`
- **THEN** parsing fails identifying `xyz` as unknown

#### Scenario: Conflicting bitrate and quality
- **WHEN** both `br:128` and `q:5` are present
- **THEN** parsing fails as a conflict (§3.1: mutually exclusive)

#### Scenario: Domain violations
- **WHEN** parsing `ch:3`, or `bd:24` with lossy `f:mp3`, or negative `t` start, or `pts:0`
- **THEN** each fails with a structured domain error

#### Scenario: Values above their upper bound
- **WHEN** parsing `br:10001`, `sr:384001`, `pts:100001`, or `gain:100.001`
- **THEN** each fails as out of range, so an unrenderable value cannot reach a later stage

#### Scenario: Control characters in opaque values
- **WHEN** parsing `dl:` or `cb:` with a value containing a control character (e.g. `cb:a\nb`)
- **THEN** parsing fails, so a normalized options string can never contain one

#### Scenario: Encoding option the codec cannot honour
- **WHEN** parsing `f:flac/br:320`, `f:wav/br:320`, or `f:wav/q:8`
- **THEN** each fails with a structured error naming the segment and the format it conflicts with

#### Scenario: Float bit depth outside wav
- **WHEN** parsing `f:flac/bd:32f`
- **THEN** parsing fails, because flac encodes integer samples only

#### Scenario: Quality on a codec whose scale is compression effort
- **WHEN** parsing `f:opus/q:8` or `f:flac/q:8`
- **THEN** parsing succeeds, and the value maps to that codec's `compression_level`

#### Scenario: Fade-out without a bounded trim
- **WHEN** parsing `fade:0:2` or `t:1/fade:2:2`
- **THEN** parsing fails, because the fade-out start cannot be computed without a duration

#### Scenario: Fade-in without a trim
- **WHEN** parsing `fade:2`
- **THEN** parsing succeeds, because a fade-in starts at zero
