## ADDED Requirements

### Requirement: Request options are signed but not cache-keyed
The options grammar SHALL distinguish variant options (normalized into the canonical options string, the cache key, and the ffmpeg args) from request options (parsed and validated in the options segment, covered by the signature as path bytes, excluded from the canonical options string, the cache key, and the ffmpeg args), and the round-trip property SHALL hold per class: variant options round-trip to an identical cache key; request options round-trip to the signed path only.

#### Scenario: Differing request options share one variant
- **WHEN** two signed URLs differ only in a request option's value
- **THEN** they produce identical cache keys, identical ffmpeg args, and concurrent requests coalesce into one render

#### Scenario: Request options are tamper-proof
- **WHEN** a request option's value in the path is altered without re-signing
- **THEN** signature verification fails exactly as for any other path byte

### Requirement: exp option
The system SHALL accept `exp:<unix-seconds>` as a request option — a bounded positive integer, duplicates rejected like any duplicate option — whose only semantic is the expiry verdict; it SHALL never influence the rendered bytes, the cache key, or the ffmpeg invocation.

#### Scenario: Past timestamps are valid grammar
- **WHEN** a correctly signed URL carries an `exp` in the past
- **THEN** parsing succeeds and the response is the expiry verdict, not an invalid-option error

#### Scenario: Malformed exp rejected
- **WHEN** `exp` carries a non-integer, a negative value, or exceeds the numeric bounds
- **THEN** the response is the invalid-option error, exactly as for a malformed variant option
