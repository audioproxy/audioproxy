## ADDED Requirements

### Requirement: Rendered variant streams as chunked 200
The system SHALL serve a valid signed render request as `200 OK` with `Transfer-Encoding: chunked`, no `Content-Length`, no `Accept-Ranges`, streaming encoder output as it is produced.

#### Scenario: End-to-end render
- **WHEN** a correctly signed request for `f:mp3/t:0:2` of a fixture WAV is made over HTTP
- **THEN** the response is 200 chunked and the received bytes are a decodable ~2 s mp3

#### Scenario: First bytes before render completes
- **WHEN** a render takes several seconds
- **THEN** initial chunks arrive before the subprocess exits (no full buffering)

### Requirement: Response headers per API §5
The system SHALL set `Content-Type` for the format, `Cache-Control: public, max-age=31536000, immutable`, `ETag` carrying the cache key as an RFC 9110 entity-tag (the key, quoted), `X-Audio-Proxy: MISS`, and `Content-Disposition: attachment` with the filename when `dl` is present.

#### Scenario: Headers on MISS
- **WHEN** a fresh variant is requested with `dl:preview.mp3`
- **THEN** all five headers are present with correct values

### Requirement: Client disconnect releases resources
The system SHALL detect client disconnect during streaming and terminate the render — no ffmpeg process survives its sole consumer.

#### Scenario: Sole client disconnects
- **WHEN** the only client closes its socket mid-stream
- **THEN** the ffmpeg process is dead shortly after

### Requirement: Render failures surface per contract
The system SHALL answer 415 for undecodable sources, 504 for renders exceeding `AP_RENDER_TIMEOUT` before first byte, and 500 `render_failed` for a pre-first-byte failure of any other kind; a failure after 200 SHALL terminate the chunked stream abnormally (connection close without final chunk).

#### Scenario: Undecodable source
- **WHEN** a signed request names a text file
- **THEN** the response is 415

#### Scenario: Pre-stream timeout
- **WHEN** the render produces no output within `AP_RENDER_TIMEOUT`
- **THEN** the response is 504

#### Scenario: Mid-stream failure after 200
- **WHEN** the render fails after chunks were sent
- **THEN** the stream terminates abnormally

#### Scenario: Unclassifiable failure before the first byte
- **WHEN** a render fails before producing output for a reason that is none of the above — no encoder on the host, a diagnostic no classifier recognises
- **THEN** the response is 500 `render_failed`

## REMOVED Requirements

### Requirement: Valid requests reach a visible placeholder
**Reason**: The streaming action replaces the 501 placeholder this requirement pinned.
**Migration**: None — the pinning test is deleted in the same change; valid requests now stream.
