## ADDED Requirements

### Requirement: enhance preset option
The system SHALL accept `enhance:voice`, applying a pinned conventional enhancement chain (high-pass, denoise, de-ess, compression) with a fixed position in the filter order, orthogonal to `norm:`, and SHALL treat preset values as immutable: a changed chain is a new value, never a mutation of an existing one.

#### Scenario: Preset renders and caches as one variant
- **WHEN** a source renders with `enhance:voice` twice with different option spellings around it
- **THEN** both hit one cache key and the chain's filters appear once in the argv

#### Scenario: Composes with norm
- **WHEN** `enhance:voice/norm:ebu` is requested
- **THEN** both apply, enhancement before loudness normalization

#### Scenario: Pinning survives improvement
- **WHEN** the chain is improved in a later release
- **THEN** it ships as a new preset value and `enhance:voice` output is byte-stable
