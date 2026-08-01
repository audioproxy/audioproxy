# render-http Specification

## Purpose
The HTTP request path every render request travels before a render exists:
routing, the plug chain, and the checks that can answer a request without ever
starting ffmpeg. Signature verification runs first, ahead of dispatch, on every
signed route; options parsing and source resolution follow; and the resolved
source is authorized and statted in the request path — unauthorized and missing
sources indistinguishable as 404, oversize as 413 — so a bad request is refused
before any render subprocess could start.

Every failure converges on one error contract: structured error values map
through a single table to the §5 JSON responses, including rows whose producers
land in later changes (415, 429, 504) but ship in the table now, unit-tested.
A request that passes every check answers 501 naming the missing streaming
capability — a deliberate, pinned gap that `add-render-endpoint` replaces.

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
The system SHALL map structured errors to §5 JSON responses through one table: 401 invalid signature, 404 source missing/unauthorized, 413 oversized, 415 undecodable, 422 invalid options, 429 queue full with `Retry-After`, 504 render timeout. Rows whose producers do not exist yet (415, 504: `add-render-endpoint`; 429: `add-render-semaphore`) SHALL ship in the table, unit-tested.

#### Scenario: Reachable errors end-to-end
- **WHEN** requests carry a bad signature, an unknown option, a disallowed source, a missing file, and an oversized file
- **THEN** they answer 401, 422, 404, 404, and 413 respectively, each with a JSON body naming the error

#### Scenario: Every row unit-tested
- **WHEN** the mapping table is exercised directly
- **THEN** all seven status codes produce their documented body shape, including `Retry-After` on 429

### Requirement: Valid requests reach a visible placeholder
Until the streaming action lands, a request passing every check SHALL answer `501` with a JSON body naming the missing capability.

#### Scenario: Pinned gap
- **WHEN** a fully valid signed render request arrives
- **THEN** the response is 501, and the pinning test is removed by `add-render-endpoint`
