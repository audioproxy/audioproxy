## ADDED Requirements

### Requirement: Ordered concatenation via payload
The system SHALL accept a `stitch` payload holding an ordered source list with optional per-boundary `xfade` seconds, resolving each segment through existing source types and the allowlist, normalizing rate and channels before concatenation, rendering in one process holding one slot, with the canonical payload in the cache key.

#### Scenario: Three segments, one variant
- **WHEN** a stitch names intro, episode, outro
- **THEN** the rendered duration is the sum of the three (minus crossfade overlaps) and the result caches as one variant

#### Scenario: Heterogeneous segments align
- **WHEN** segments differ in sample rate or channel count
- **THEN** the output is coherent at the negotiated output rate and channels, not an ffmpeg error

#### Scenario: Every segment authorized
- **WHEN** any segment fails the allowlist
- **THEN** 404, nothing renders
