## ADDED Requirements

### Requirement: Prometheus exposition endpoint
The system SHALL serve `GET /metrics` in Prometheus text exposition format (0.0.4), unsigned, on a listener of its own bound to `AP_METRICS_BIND:AP_METRICS_PORT`. The response SHALL carry `Content-Type: text/plain; version=0.0.4` and `Cache-Control: no-store`, and every exported metric SHALL be declared whether or not it currently has samples.

The bind is the access control: `AP_METRICS_BIND` SHALL accept an IP address literal only, refusing a hostname at boot, and a port equal to the listener's SHALL be refused at boot.

#### Scenario: Valid exposition
- **WHEN** `/metrics` is scraped
- **THEN** the body parses as Prometheus text format with `# HELP`/`# TYPE` lines for every exported metric, including those with no samples yet

#### Scenario: Bind restriction
- **WHEN** a request for `/metrics` arrives on the public listener
- **THEN** it is answered `404`, not served there and not answered `401`

#### Scenario: Port collision refused at boot
- **WHEN** `AP_METRICS_PORT` equals the listener port
- **THEN** the container fails to start with an error naming both variables

### Requirement: Render metrics
The system SHALL export render counts and duration histograms labeled by output format and outcome, plus a gauge of running renders.

`outcome` is `success` for a render the client received whole, `cancelled` for one abandoned because the client went away, and otherwise the failure class. The running-renders gauge counts *renders*, not requests: requests coalesced onto one render count once. Histogram bucket edges are fixed rather than configurable, so the histogram stays aggregatable across nodes and releases.

#### Scenario: Render observed
- **WHEN** a render completes successfully
- **THEN** `renders_total{format="mp3",outcome="success"}` increments and its duration lands in the histogram

#### Scenario: Coalesced renders counted once
- **WHEN** several requests share one render
- **THEN** the running-renders gauge reports one

### Requirement: Queue and cache metrics
The system SHALL export semaphore occupancy and queue depth as gauges, alongside the capacities they are measured against, a counter of requests the semaphore refused for want of queue room, cache outcome counters (hit, miss, coalesced), and a counter of variant-store write-back failures.

The occupancy and depth gauges SHALL be sampled when scraped rather than accumulated from events, so that they cannot drift from the semaphore's own state.

The rejection counter counts *semaphore* rejections. A request answered `429` because it waited for a slot until its deadline expired is not one, so this counter is a lower bound on `429`s rather than a count of them.

#### Scenario: Cache outcomes tracked
- **WHEN** a MISS, a HIT, and a COALESCED request occur
- **THEN** each increments its respective counter

#### Scenario: Only committed responses counted
- **WHEN** a request is answered without committing to a cache outcome — a `HEAD`, a `304`, or a `429`
- **THEN** no cache outcome counter increments, so the hit ratio's denominator is requests that were actually told an outcome

#### Scenario: Rejection tracked
- **WHEN** the semaphore refuses a request because the wait queue was full
- **THEN** the rejection counter increments

#### Scenario: Silent cache failure is visible
- **WHEN** a completed render cannot be written back to the variant store
- **THEN** the write-failure counter increments, even though every client was served

### Requirement: HTTP metrics
The system SHALL export request counters labeled by endpoint class and status code family.

Endpoint classes are the route classes the router assigns (`render`, `info`, `health`, `ready`, `metrics`, `unknown`). Status families are `2xx` through `5xx`, plus `unknown` for a request that ended without a status. A request the server could not parse into a connection at all SHALL NOT be attributed to any endpoint class.

#### Scenario: Status families
- **WHEN** requests produce 200, 404, and 504 responses
- **THEN** counters with the corresponding labels increment

#### Scenario: Scrapes are requests too
- **WHEN** `/metrics` is scraped
- **THEN** the scrape is counted under its own endpoint class, so a scraper that stops reaching the port is visible from the last scrape that did

### Requirement: Bounded label cardinality
Every label value the system exports SHALL come from a bounded set the application defines. No value derived from a client request — source, processing options, cache key, path — SHALL be used as a label value.

#### Scenario: Client input never becomes a label
- **WHEN** requests arrive for arbitrarily many distinct sources and option combinations
- **THEN** the exported series count does not grow with them
