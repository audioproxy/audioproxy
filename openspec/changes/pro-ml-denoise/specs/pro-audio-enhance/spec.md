## ADDED Requirements

### Requirement: studio preset with ML denoise
The system SHALL accept `enhance:studio`, applying a pinned arnndn model plus the pinned voice chain, with the model shipped and licensed in the image manifest, and any change to chain or model introduced as a new preset value rather than mutating `studio`.

#### Scenario: Noise measurably reduced
- **WHEN** a fixture with synthetic noise renders with `enhance:studio`
- **THEN** noise-band energy drops measurably versus `enhance:voice` output

#### Scenario: Presets are distinct variants
- **WHEN** the same source renders with `voice` and `studio`
- **THEN** they occupy distinct cache keys
