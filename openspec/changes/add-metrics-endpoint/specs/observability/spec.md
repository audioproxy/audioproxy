## ADDED Requirements

### Requirement: Prometheus exposition endpoint
The system SHALL serve `GET /metrics` in Prometheus text exposition format (0.0.4), unsigned, reachable only via the configured metrics bind address.

#### Scenario: Valid exposition
- **WHEN** `/metrics` is scraped
- **THEN** the body parses as Prometheus text format with `# HELP`/`# TYPE` lines for every exported metric

#### Scenario: Bind restriction
- **WHEN** the metrics bind is loopback and a request arrives on the public listener
- **THEN** `/metrics` is not served there (404 on public listener)

### Requirement: Render metrics
The system SHALL export render counts and duration histograms labeled by output format and outcome (success, error class), plus a gauge of running renders.

#### Scenario: Render observed
- **WHEN** a render completes successfully
- **THEN** `renders_total{format="mp3",outcome="success"}` increments and its duration lands in the histogram

### Requirement: Queue and cache metrics
The system SHALL export semaphore occupancy and queue depth gauges, queue rejections (429) counter, and cache outcome counters (hit, miss, coalesced).

#### Scenario: Cache outcomes tracked
- **WHEN** a MISS, a HIT, and a COALESCED request occur
- **THEN** each increments its respective counter

#### Scenario: Rejection tracked
- **WHEN** a request is rejected with 429
- **THEN** the rejection counter increments

### Requirement: HTTP metrics
The system SHALL export request counters labeled by endpoint class (render, info, health) and status code family.

#### Scenario: Status families
- **WHEN** requests produce 200, 404, and 504 responses
- **THEN** counters with the corresponding labels increment
