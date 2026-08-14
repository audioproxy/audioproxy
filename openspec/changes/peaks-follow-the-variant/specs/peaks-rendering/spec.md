## MODIFIED Requirements

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
