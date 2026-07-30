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
The system SHALL set `Content-Type` for the format, `Cache-Control: public, max-age=31536000, immutable`, `ETag` equal to the cache key, `X-Audio-Proxy: MISS` (or `COALESCED`), and `Content-Disposition: attachment` with the filename when `dl` is present.

#### Scenario: Header set on MISS
- **WHEN** a fresh variant is requested with `dl:preview.mp3`
- **THEN** all five headers are present with correct values

#### Scenario: Coalesced request marked
- **WHEN** a second client requests the same in-flight variant
- **THEN** it receives `X-Audio-Proxy: COALESCED` and the same bytes

### Requirement: Client disconnect releases resources
The system SHALL detect client disconnect during streaming and unsubscribe, so a sole client's disconnect terminates the subprocess (via coalescing) and frees the slot.

#### Scenario: Sole client disconnects
- **WHEN** the only client closes its socket mid-stream
- **THEN** the ffmpeg process is dead and the semaphore slot free shortly after

### Requirement: Error contract
The system SHALL return JSON error bodies with the §5 status codes: 401 invalid signature, 404 source missing/unauthorized, 413 source exceeding `AP_MAX_SRC_BYTES`, 415 undecodable, 422 invalid options, 429 queue full with `Retry-After`, 504 render timeout.

#### Scenario: Each error path
- **WHEN** requests exercise each failure (bad sig; missing object; oversized source; text-file source; `br:0`; saturated queue; hanging render)
- **THEN** each returns its specified status with a JSON body naming the error

#### Scenario: Mid-stream failure after 200
- **WHEN** the render fails after chunks were sent
- **THEN** the chunked stream terminates abnormally (connection close without final chunk)
