## ADDED Requirements

### Requirement: Valid signatures are accepted
The system SHALL accept a request when the first path segment equals `base64url(HMAC-SHA256(key, salt ‖ rest-of-path))`, where rest-of-path is the exact byte sequence after the signature segment (leading `/` included), and key/salt are the hex-decoded `AP_KEY`/`AP_SALT`.

#### Scenario: Known-answer verification
- **WHEN** a request path is signed with the reference implementation using the configured key and salt
- **THEN** the verification plug passes the request through unchanged

#### Scenario: Signature covers the whole remainder
- **WHEN** any byte after the signature segment changes (option, source, escaping)
- **THEN** verification fails with 401

### Requirement: Invalid signatures are rejected with 401
The system SHALL respond 401 with a JSON error body when the signature is missing, malformed base64url, or does not match, and SHALL use a constant-time comparison.

#### Scenario: Tampered signature
- **WHEN** a valid signature has one character altered
- **THEN** the response is 401 with a JSON error body

#### Scenario: Garbage signature segment
- **WHEN** the signature segment is not decodable base64url
- **THEN** the response is 401 (not 500)

### Requirement: Insecure dev mode
The system SHALL accept the literal signature `insecure` only when `AP_ALLOW_INSECURE` is enabled; otherwise it SHALL be treated as an invalid signature.

#### Scenario: Dev mode enabled
- **WHEN** `AP_ALLOW_INSECURE=true` and the path starts with `/insecure/`
- **THEN** the request passes verification

#### Scenario: Dev mode disabled (default)
- **WHEN** `AP_ALLOW_INSECURE` is unset and the path starts with `/insecure/`
- **THEN** the response is 401
