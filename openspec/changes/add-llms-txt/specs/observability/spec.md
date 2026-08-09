## MODIFIED Requirements

### Requirement: HTTP metrics
The system SHALL export request counters labeled by endpoint class and status code family.

Endpoint classes are the route classes the router assigns (`render`, `info`, `health`, `ready`, `metrics`, `llms`, `unknown`). Status families are `2xx` through `5xx`, plus `unknown` for a request that ended without a status. A request the server could not parse into a connection at all SHALL NOT be attributed to any endpoint class.

#### Scenario: Status families
- **WHEN** requests produce 200, 404, and 504 responses
- **THEN** counters with the corresponding labels increment

#### Scenario: Scrapes are requests too
- **WHEN** `/metrics` is scraped
- **THEN** the scrape is counted under its own endpoint class, so a scraper that stops reaching the port is visible from the last scrape that did

#### Scenario: The llms.txt documents are their own class
- **WHEN** `/llms.txt` or `/llms-full.txt` is fetched
- **THEN** the request is counted under endpoint class `llms`, rather than as the `unknown` an unrouted path produces
