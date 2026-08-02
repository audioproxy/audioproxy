## ADDED Requirements

### Requirement: Every request logs one line
The system SHALL emit exactly one log line per completed HTTP request carrying the request id, endpoint class, normalized options, canonical source, response status, duration, and bytes sent, at a level determined by outcome: info for 2xx/3xx/4xx, warning for 5xx and render timeouts.

#### Scenario: Successful render logged
- **WHEN** a signed render request completes with 200
- **THEN** one info line contains the endpoint class, the normalized options string, the canonical source, 200, the duration, and bytes sent

#### Scenario: Client errors are calm
- **WHEN** requests produce 401, 404, and 422
- **THEN** each logs one info line naming the error class — no warnings, no stack traces

#### Scenario: Server-side failures stand out
- **WHEN** a render times out (504) or dies (mid-stream or 500-class)
- **THEN** the line logs at warning with the failure class

#### Scenario: Health checks stay quiet
- **WHEN** `/health` is polled at the default log level
- **THEN** no line is emitted; at debug level it appears

### Requirement: Render lifecycle is observable
The system SHALL emit telemetry events for render start, stop, and exception carrying format, canonical source, duration, bytes produced, and failure class, and the log handler SHALL consume them — so the metrics slice can attach its aggregator to the same events without new instrumentation.

#### Scenario: Events carry the documented shape
- **WHEN** a render completes or fails under a test telemetry handler
- **THEN** start/stop (or exception) events fire with the documented measurements and metadata

#### Scenario: One instrumentation, two consumers
- **WHEN** a second handler attaches to the same events
- **THEN** it observes identical data without any change to the render path

### Requirement: Log level is configurable
The system SHALL read `AP_LOG_LEVEL` (`debug` | `info` | `warning` | `error`, default `info`) at boot and apply it to the primary logger; an invalid value SHALL fail boot naming the variable.

#### Scenario: Quiet production
- **WHEN** `AP_LOG_LEVEL=warning`
- **THEN** request info lines are suppressed and failure warnings still appear

#### Scenario: Invalid level
- **WHEN** `AP_LOG_LEVEL=verbose`
- **THEN** boot fails with an error naming `AP_LOG_LEVEL` and the allowed values

### Requirement: Logs never contain credentials
Log output SHALL never include presigned URLs, `X-Amz-*` parameters, or credential material; render inputs are logged as their canonical source identity only. This SHALL hold on every path, including failure paths that log diagnostics.

#### Scenario: Failure diagnostics stay clean
- **WHEN** a render fails with an input URL carrying an `X-Amz-Signature` and all log output is captured
- **THEN** no captured line contains `X-Amz` or the URL's query string, while the canonical source identity is present
