# render-http Specification

## Purpose
The HTTP request path a render request travels: routing, the plug chain, the
checks that can answer without ever starting ffmpeg, and the streaming of what
ffmpeg produces. Signature verification runs first, ahead of dispatch, on every
signed route; options parsing and source resolution follow; and the resolved
source is authorized and statted in the request path — unauthorized and missing
sources indistinguishable as 404, oversize as 413 — so a bad request is refused
before any render subprocess could start.

A request that survives all of it becomes a render, streamed to the client as a
chunked 200 as the encoder produces it, carrying the §5 headers that describe
the variant. Client disconnect terminates the render rather than leaving an
encoder writing into a socket nobody reads.

Every failure converges on one error contract: structured error values map
through a single table to the §5 JSON responses. Which status a render failure
becomes is decided here from the class the render pipeline reports, and the
first byte is the dividing line — before it, a failure is still an ordinary
JSON response; after it, the status line is spent and the only signal left is
an abnormal close. Rows whose producers land in later changes (429,
`add-render-semaphore`) ship in the table now, unit-tested.

## Requirements
### Requirement: Signed routing
The system SHALL route `GET /{sig}/{options}/{source}` through signature verification before any other processing; every signed route SHALL answer 401 without a valid signature, and `/health` SHALL remain unsigned.

#### Scenario: Unsigned request refused
- **WHEN** any signed route is requested without a valid signature
- **THEN** the response is 401, proving verification is mounted ahead of dispatch on every route

#### Scenario: Health stays open
- **WHEN** `/health` is requested with no signature
- **THEN** it answers 200

### Requirement: Sources are checked before rendering
The system SHALL authorize and stat the resolved source in the request path: unauthorized or missing sources answer 404 (indistinguishable, no existence oracle), and a source larger than `AP_MAX_SRC_BYTES` answers 413 — all before any render subprocess could start.

#### Scenario: Missing file
- **WHEN** a signed request names a nonexistent file under the local root
- **THEN** the response is 404

#### Scenario: Oversized source
- **WHEN** the statted size exceeds `AP_MAX_SRC_BYTES`
- **THEN** the response is 413

#### Scenario: Unauthorized equals absent
- **WHEN** one request fails authorization and another names a missing file
- **THEN** both responses are identical 404s

### Requirement: Error contract
The system SHALL map structured errors to §5 JSON responses through one table: 401 invalid signature, 404 source missing/unauthorized, 413 oversized, 415 undecodable, 422 invalid options, 429 queue full with `Retry-After`, 500 render failed, 504 render timeout. The 500 row extends §5's table deliberately: §5 enumerates what a client got wrong, and a render can fail for none of those reasons. Rows whose producers do not exist yet (429: `add-render-semaphore`) SHALL ship in the table, unit-tested.

#### Scenario: Reachable errors end-to-end
- **WHEN** requests carry a bad signature, an unknown option, a disallowed source, a missing file, and an oversized file
- **THEN** they answer 401, 422, 404, 404, and 413 respectively, each with a JSON body naming the error

#### Scenario: Every row unit-tested
- **WHEN** the mapping table is exercised directly
- **THEN** every status code produces its documented body shape, including `Retry-After` on 429

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
