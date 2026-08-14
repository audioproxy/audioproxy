## ADDED Requirements

### Requirement: Enhancement presets map to a pinned filter chain
The command builder SHALL map each `enhance` preset value to one exact filter chain of stock ffmpeg filters, emitted first in the filtergraph — ahead of `loudnorm`, `volume`, `aresample` and `afade` — and SHALL treat that mapping as immutable: a preset value's chain is fixed for the life of the value, and an improved chain is published as a new value rather than as an edit to an existing one.

#### Scenario: The preset conditions the source before every other stage
- **WHEN** building `enhance:voice` alongside `norm`, `gain`, `sr` and `fade`
- **THEN** the preset's filters run first, so loudness is measured on the enhanced signal rather than on audio a later stage is about to change

#### Scenario: The chain is pinned against silent retuning
- **WHEN** a preset's filter parameters are changed without minting a new preset value
- **THEN** a test comparing the published chain against a literal fails, because the cache key names the preset rather than its parameters and cached variants would otherwise be served for a chain that no longer produces them

#### Scenario: The chain needs no dependency beyond ffmpeg
- **WHEN** a preset chain is built
- **THEN** every filter in it is one stock ffmpeg provides, so no preset requires a new package, build flag or non-redistributable encoder
