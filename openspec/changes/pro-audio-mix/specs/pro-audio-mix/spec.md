## ADDED Requirements

### Requirement: Multi-track mix via payload
The system SHALL accept a `mix` payload holding an ordered track list (program first, then overlays with `at` seconds, `gain` dB, `loop`, `duck`), resolving every track through the existing source types and allowlist, rendering the composition in one ffmpeg process holding one semaphore slot, with the canonical payload participating in the cache key.

#### Scenario: Bed under voice with ducking
- **WHEN** a mix names a speech program and a bed track with `duck: true`
- **THEN** the rendered bed level drops while speech is present and recovers in gaps, and the output caches as one variant

#### Scenario: Composition is one cache key
- **WHEN** the same track list is spelled with different key order or number formats
- **THEN** both URLs hit one cached variant

#### Scenario: Every track is authorized
- **WHEN** any track's source fails the allowlist
- **THEN** the response is 404, identical to a single-source refusal, and nothing renders

#### Scenario: Downstream options apply to the mix
- **WHEN** a mix URL also carries `t:` and `f:opus`
- **THEN** the trim and encode apply to the composed program
