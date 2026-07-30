# app-runtime Specification

## Purpose
How the service comes up and what it reads to configure itself: the OTP
application and its supervision tree, the HTTP listener, the unsigned `/health`
endpoint, and the `AP_`-prefixed environment surface defined by
`docs/audio-proxy-api-v1.md` §6.

The through-line is fail-fast: configuration is parsed, typed, and validated once
at boot, so a misconfigured deployment refuses to start instead of serving
traffic under surprising defaults. Everything the signed render path needs later
— signing keys, source allowlist, variant bucket, concurrency and abuse limits,
serve mode — is validated here, whether or not anything consumes it yet.

Out of scope: the signed URL space, rendering, and S3 access. Those belong to
`url-signing`, `render-*`, and `s3-access`.

## Requirements
### Requirement: Application boots with a supervision tree
The system SHALL start as an OTP application supervising the HTTP listener, and SHALL fail fast at boot when required configuration is invalid.

#### Scenario: Clean boot
- **WHEN** the application starts with valid configuration
- **THEN** the supervision tree starts and the Bandit listener accepts connections on the configured port

#### Scenario: Invalid configuration aborts boot
- **WHEN** a required env var is malformed (e.g., `AP_KEY` is not valid hex)
- **THEN** the application refuses to boot with a descriptive error naming the offending variable

### Requirement: Configuration is read from AP_-prefixed env vars only
The system SHALL read all configuration from `AP_`-prefixed environment variables with documented defaults, and SHALL expose typed values (integers, booleans, lists) to the rest of the application.

#### Scenario: Defaults applied
- **WHEN** an optional var such as `AP_MAX_CONCURRENCY` is unset
- **THEN** the config exposes its documented default (schedulers online)

#### Scenario: Typed parsing
- **WHEN** `AP_QUEUE_SIZE=32` is set in the environment
- **THEN** the config exposes the integer `32`, not the string `"32"`

#### Scenario: Unknown values rejected
- **WHEN** `AP_SERVE_MODE=banana` is set
- **THEN** boot fails with an error listing the allowed values (`redirect`, `proxy`)

### Requirement: Health endpoint
The system SHALL serve `GET /health` unsigned, returning 200 when the service is able to accept renders.

#### Scenario: Liveness
- **WHEN** a client requests `GET /health`
- **THEN** the service responds 200 with a small JSON body, without requiring a signature

