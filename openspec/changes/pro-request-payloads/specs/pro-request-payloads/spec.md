## ADDED Requirements

### Requirement: Signed payload envelope
The system SHALL support path segments of the form `{key}:{base64url(JSON)}` (unpadded), signature-covered as ordinary path bytes, with the decoded payload bounded in size, parsed strictly (malformed input maps to the invalid-option error), and canonicalized (sorted keys, normalized numbers, significant array order) before any cache-key use, so equivalent payloads are one cache key.

#### Scenario: Equivalent spellings are one key
- **WHEN** two payloads differ only in object key order, number formatting, or whitespace
- **THEN** their canonical forms and any derived cache keys are identical

#### Scenario: Oversized payload refused
- **WHEN** a decoded payload exceeds the size bound
- **THEN** the response is the invalid-option error, before any schema processing

#### Scenario: Tamper-proof
- **WHEN** a payload byte changes without re-signing
- **THEN** signature verification fails
