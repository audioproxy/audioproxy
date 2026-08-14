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
The system SHALL map structured errors to §5 JSON responses through one table: 401 invalid signature, 404 source missing/unauthorized, 413 oversized, 415 undecodable, 422 invalid options, 429 queue full with `Retry-After`, 500 render failed, 500 storage misconfigured, 502 upstream storage unavailable, 504 render timeout. The 500 and 502 rows extend §5's table deliberately: §5 enumerates what a client got wrong, and neither a failed render nor an unreachable store is that. 502 SHALL carry `Cache-Control: no-store` and SHALL be distinct from the blind 404 — an outage says nothing about whether the object exists, and answering 404 reports a deletion that did not happen and then caches it. Rows whose producers do not exist yet SHALL ship in the table, unit-tested.

#### Scenario: Reachable errors end-to-end
- **WHEN** requests carry a bad signature, an unknown option, a disallowed source, a missing file, and an oversized file
- **THEN** they answer 401, 422, 404, 404, and 413 respectively, each with a JSON body naming the error

#### Scenario: Every row unit-tested
- **WHEN** the mapping table is exercised directly
- **THEN** every status code produces its documented body shape, including `Retry-After` on 429

#### Scenario: Upstream failure is not a source failure
- **WHEN** the storage backend reports a transport failure or an upstream 5xx
- **THEN** the response is 502 with `no-store`, distinguishable by the client from the 404 that names a missing object

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

### Requirement: CORS headers gated on AP_ALLOW_ORIGIN
The system SHALL send CORS headers only when `AP_ALLOW_ORIGIN` is set — to a single origin or `*`, validated at boot — adding `Access-Control-Allow-Origin`, `Vary: Origin` (for a non-`*` value), and `Access-Control-Expose-Headers: x-audio-proxy, retry-after, accept-ranges, etag` to every main-listener response including errors; with the variable unset, responses SHALL be byte-identical to a proxy without this feature.

#### Scenario: Cross-origin peaks fetch succeeds
- **WHEN** `AP_ALLOW_ORIGIN` names the page's origin and the page `fetch()`es a signed `f:peaks` URL
- **THEN** the browser delivers the body, and the page can read `x-audio-proxy` from the response

#### Scenario: Backoff is readable cross-origin
- **WHEN** a cross-origin `fetch()` receives the queue-full 429
- **THEN** `Retry-After` is exposed to the page, not hidden by the CORS filter

#### Scenario: Errors carry the headers too
- **WHEN** a cross-origin `fetch()` receives any §5 error response
- **THEN** the error envelope is readable by the page

#### Scenario: Unset means today
- **WHEN** `AP_ALLOW_ORIGIN` is unset
- **THEN** no `Access-Control-*` header appears on any response and `OPTIONS` answers 404

#### Scenario: Invalid origin refused at boot
- **WHEN** `AP_ALLOW_ORIGIN` is set to something that is neither `*` nor a scheme://host[:port] origin
- **THEN** boot aborts naming the variable

### Requirement: Preflight handler when CORS is enabled
When `AP_ALLOW_ORIGIN` is set, the system SHALL answer `OPTIONS` requests with 204 carrying `Access-Control-Allow-Methods: GET, HEAD`, an echo of the requested headers, and `Access-Control-Max-Age: 86400` — the one scoped exception to the rule that non-GET methods answer 404 everywhere.

#### Scenario: Preflight passes
- **WHEN** a browser sends `OPTIONS` with `Access-Control-Request-Method: GET` and CORS is enabled
- **THEN** the response is 204 with the allow headers and no body

#### Scenario: No preflight surface when disabled
- **WHEN** CORS is not enabled
- **THEN** `OPTIONS` answers 404 exactly as any other non-GET method

### Requirement: The signed chain has one mounting
The system SHALL mount the checks every signed request passes before its action — signature verification, option parsing, expiry, source resolution — from a single shared unit that the production pipeline and every test pipeline compose, so that a check added to the chain reaches the deployed request path and the test mountings together and cannot be present in one while absent from another.

#### Scenario: A check cannot be mounted in the tests but not in production
- **WHEN** a plug is added to or removed from the shared unit
- **THEN** the production pipeline and every test pipeline change with it, and no hand-copied plug list exists that could disagree

#### Scenario: Removing a check fails the suite
- **WHEN** any plug is removed from the shared unit
- **THEN** the existing suite fails, because the tests exercise the same mounting the deployment runs

#### Scenario: Behaviour is unchanged
- **WHEN** the refactor lands
- **THEN** the request path is observably identical — the suite passes with no test edits, which is what demonstrates it

