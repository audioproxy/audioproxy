## ADDED Requirements

### Requirement: Operator-configured periodic stamp
The system SHALL overlay an operator-configured stamp source every `wm:<seconds>` over the rendered program, at `wm_gain` dB, with the stamp's content identity participating in the cache key, the stamp source validated at boot, and `wm:` on a proxy with no stamp configured answering the not-configured error.

#### Scenario: Stamp recurs at the interval
- **WHEN** a 60-second preview renders with `wm:20`
- **THEN** the stamp is audible at approximately 0, 20, and 40 seconds

#### Scenario: Stamp swap invalidates cache
- **WHEN** the operator replaces the stamp file and restarts
- **THEN** previously cached watermarked variants are not served for new requests

#### Scenario: URL cannot choose the stamp
- **WHEN** any URL is constructed
- **THEN** no URL input selects or replaces the stamp source; only configuration does
