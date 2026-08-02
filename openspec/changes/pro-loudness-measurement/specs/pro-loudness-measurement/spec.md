## ADDED Requirements

### Requirement: Loudness measurement endpoint
The system SHALL serve `GET /{sig}/measure/{source}` returning a JSON object with the source's measured integrated loudness (`input_i`, LUFS), true peak (`input_tp`, dBTP), loudness range (`input_lra`, LU), threshold (`input_thresh`), duration, and canonical source — derived from a full-length `loudnorm` analysis pass. Processing options SHALL be rejected (422), as with `info`.

#### Scenario: Known signal measured
- **WHEN** measurement runs on a generated sine at a known level
- **THEN** `input_i` matches the expected LUFS within ±0.5 LU and `input_tp` the expected peak within ±0.5 dB

#### Scenario: Whole source, not an excerpt
- **WHEN** a source is loud in its first half and silent in its second
- **THEN** the measurement reflects the full duration — there is no way to measure a trim

#### Scenario: Options rejected
- **WHEN** the request carries any processing option alongside `measure`
- **THEN** the response is 422

### Requirement: Measurement is render-class work
Measurement passes SHALL consume a render concurrency slot and SHALL coalesce: concurrent measure requests for one source share a single analysis pass.

#### Scenario: Slot accounting
- **WHEN** measurement runs while the render semaphore is saturated
- **THEN** it queues like a render and 429s on overflow

#### Scenario: Concurrent measures coalesce
- **WHEN** several clients measure the same source simultaneously
- **THEN** one subprocess runs and all receive the same result

### Requirement: Measurement responses are cacheable
The system SHALL emit a strong `ETag` tied to the source object's identity and content (bucket/key + source ETag), answer `If-None-Match` with 304, and carry long-lived `Cache-Control` — a source's measurement never changes while its bytes don't.

#### Scenario: Conditional revalidation
- **WHEN** a client repeats the request with the previous `ETag`
- **THEN** the response is 304 with no analysis pass run

### Requirement: Failures map to the error contract
Unreadable sources SHALL answer 404, unprobeable/undecodable sources 415, and analysis exceeding the render timeout 504 — through the existing error mapping.

#### Scenario: Undecodable source
- **WHEN** measurement is requested for a text file
- **THEN** the response is 415
