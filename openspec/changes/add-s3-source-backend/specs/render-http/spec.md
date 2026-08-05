## MODIFIED Requirements

### Requirement: Error contract
The system SHALL map structured errors to §5 JSON responses through one table: 401 invalid signature, 404 source missing/unauthorized, 413 oversized, 415 undecodable, 422 invalid options, 429 queue full with `Retry-After`, 500 render failed, 502 upstream storage unavailable, 504 render timeout. The 500 and 502 rows extend §5's table deliberately: §5 enumerates what a client got wrong, and neither a failed render nor an unreachable store is that. 502 SHALL carry `Cache-Control: no-store` and SHALL be distinct from the blind 404 — an outage says nothing about whether the object exists, and answering 404 reports a deletion that did not happen and then caches it. Rows whose producers do not exist yet SHALL ship in the table, unit-tested.

#### Scenario: Reachable errors end-to-end
- **WHEN** requests carry a bad signature, an unknown option, a disallowed source, a missing file, and an oversized file
- **THEN** they answer 401, 422, 404, 404, and 413 respectively, each with a JSON body naming the error

#### Scenario: Every row unit-tested
- **WHEN** the mapping table is exercised directly
- **THEN** every status code produces its documented body shape, including `Retry-After` on 429

#### Scenario: Upstream failure is not a source failure
- **WHEN** the storage backend reports a transport failure or an upstream 5xx
- **THEN** the response is 502 with `no-store`, distinguishable by the client from the 404 that names a missing object
