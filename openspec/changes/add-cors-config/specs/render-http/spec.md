## ADDED Requirements

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
