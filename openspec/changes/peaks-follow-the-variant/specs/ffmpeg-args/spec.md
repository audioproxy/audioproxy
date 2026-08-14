## MODIFIED Requirements

### Requirement: Loudness normalization without an explicit sample rate
The system SHALL resample a normalized render back to **the source's own sample rate** rather than to a fixed 48 kHz, since §3.1 defines an absent `sr` as "follow the source". For a lossy format the rate SHALL be clamped to the §3.1 lossy ceiling. Where no probe supplied the source's rate, the render SHALL fall back to 48 kHz, documented rather than silent.

#### Scenario: A normalized render keeps the source's rate
- **WHEN** `norm:ebu` is requested with no `sr` for a 44.1 kHz source
- **THEN** the argv resamples to 44100, not 48000, because single-pass `loudnorm` emits 192 kHz and the render must return to the rate the request implied

#### Scenario: A high-rate master is not silently downsampled
- **WHEN** `norm:ebu` is requested with no `sr` for a 96 kHz source and a lossless format
- **THEN** the argv resamples to 96000

#### Scenario: A lossy format stays under the ceiling
- **WHEN** `norm:ebu` is requested with no `sr` for a 96 kHz source and a lossy format
- **THEN** the argv resamples to the lossy ceiling rather than the source's rate

### Requirement: The builder is given the source's own properties
The command builder SHALL receive the resolved source's sample rate and bit depth alongside its type, supplied from the probe the render already runs, so the options documented as following the source can do so.

#### Scenario: A lossless variant follows the source's depth
- **WHEN** a lossless format is requested with no `bd` and the probe reported the source's bit depth
- **THEN** the argv encodes at that depth rather than at the 16-bit fallback

#### Scenario: The fallbacks stay documented
- **WHEN** no probe metadata is available for a render
- **THEN** the argv falls back to 16-bit and 48 kHz, the same values it uses today
