# url-signing Specification

## Purpose
Every URL is signed, so the proxy's entire API surface stays publicly
routable without being publicly usable. The signature is the first path
segment and covers the raw request path exactly as the client built it —
verification never re-encodes anything, which keeps escaping ambiguities out
of the security boundary. Signatures are also non-malleable: strict
canonicality means a leaked or logged URL cannot be respelled into new
distinct URLs that all verify.

The reference signer (`AudioProxy.Signature.sign/3`) doubles as the client
contract: tests, README examples, and third-party implementations all check
against the same known-answer vectors.

## Requirements

### Requirement: Valid signatures are accepted
The system SHALL accept a request when the first path segment equals `base64url(HMAC-SHA256(key, salt ‖ rest-of-path))`, where rest-of-path is the exact byte sequence after the signature segment (leading `/` included), taken from the raw (still percent-encoded) request path, and key/salt are the hex-decoded `AP_KEY`/`AP_SALT`.

#### Scenario: Known-answer verification
- **WHEN** a request path is signed with the reference implementation using the configured key and salt
- **THEN** the verification plug passes the request through unchanged

#### Scenario: Signature covers the whole remainder
- **WHEN** any byte after the signature segment changes (option, source, escaping)
- **THEN** verification fails with 401

#### Scenario: Adapter preserves the signed bytes
- **WHEN** a signed URL contains percent-escapes (`%20`, `%2F`)
- **THEN** the web adapter hands verification the raw, undecoded request path byte-identical to what the client signed

### Requirement: Invalid signatures are rejected with 401
The system SHALL respond 401 with a JSON error body when the signature is missing, malformed base64url, non-canonical, or does not match, and SHALL use a constant-time comparison. A signature is 43 unpadded base64url characters or the same 43 with one trailing `=`; over-padding and the final-character variants that decode to the same bytes SHALL be rejected, so each signature has exactly two accepted spellings.

#### Scenario: Tampered signature
- **WHEN** a valid signature has one character altered
- **THEN** the response is 401 with a JSON error body

#### Scenario: Garbage signature segment
- **WHEN** the signature segment is not decodable base64url
- **THEN** the response is 401 (not 500)

#### Scenario: Non-canonical signature spelling
- **WHEN** a signature is over-padded or its final character is one of the non-canonical variants decoding to the same bytes
- **THEN** the response is 401, even though the decoded MAC matches

### Requirement: Insecure dev mode
The system SHALL accept the literal signature `insecure` only when `AP_ALLOW_INSECURE` is enabled; otherwise it SHALL be treated as an invalid signature.

#### Scenario: Dev mode enabled
- **WHEN** `AP_ALLOW_INSECURE=true` and the path starts with `/insecure/`
- **THEN** the request passes verification

#### Scenario: Dev mode disabled (default)
- **WHEN** `AP_ALLOW_INSECURE` is unset and the path starts with `/insecure/`
- **THEN** the response is 401
