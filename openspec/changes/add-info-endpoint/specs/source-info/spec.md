## ADDED Requirements

### Requirement: Probe metadata as JSON
The system SHALL serve `GET /{sig}/info/{source}` returning the §4 JSON object — `format`, `duration` (seconds, float), `sample_rate`, `channels`, `bit_depth` (when applicable), `bitrate`, `size`, `tags` — derived from ffprobe and filtered to that contract.

#### Scenario: WAV fixture probed
- **WHEN** info is requested for a generated 48 kHz stereo 16-bit WAV of known duration
- **THEN** the JSON reports format `wav`, the expected duration (±0.1 s), 48000, 2, 16, and the object size

#### Scenario: Lossy source omits bit depth
- **WHEN** info is requested for an mp3 source
- **THEN** `bit_depth` is absent/null and `bitrate` is populated

#### Scenario: Tags passthrough
- **WHEN** the source carries title/artist tags
- **THEN** they appear under `tags`

### Requirement: Options are rejected on info requests
The system SHALL reject processing options combined with `info` (422) — info takes no processing options per §2.

#### Scenario: Options with info
- **WHEN** requesting `/{sig}/info/br:128/{source}`
- **THEN** the response is 422

### Requirement: Info responses are cacheable
The system SHALL emit a strong `ETag` tied to the source object's identity (bucket/key + source ETag) and long-lived `Cache-Control`, and answer `If-None-Match` with 304.

#### Scenario: Conditional revalidation
- **WHEN** a client repeats the request with the previous `ETag` in `If-None-Match`
- **THEN** the response is 304 with no body

### Requirement: Probe failures map to the error contract
The system SHALL return 404 for unreadable/missing sources and 415 for sources ffprobe cannot parse.

#### Scenario: Unprobeable source
- **WHEN** info is requested for a text file
- **THEN** the response is 415 with a JSON error
