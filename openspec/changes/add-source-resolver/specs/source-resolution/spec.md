## ADDED Requirements

### Requirement: Source segment parses into a typed source
The system SHALL parse the path remainder after the options into `plain/s3://{bucket}/{key}`, `plain/{https-url}`, or `enc/{base64url(source)}` forms, yielding a typed S3 or HTTP source with URL-escaping resolved.

#### Scenario: S3 source
- **WHEN** parsing `plain/s3://masters/2026/piece-final.wav`
- **THEN** the result is an S3 source with bucket `masters` and key `2026/piece-final.wav`

#### Scenario: Escaped key round-trips
- **WHEN** an S3 key contains spaces or `+` and is URL-escaped in the path
- **THEN** the parsed key contains the original unescaped bytes

#### Scenario: Encoded form equivalence
- **WHEN** parsing `enc/{base64url("s3://masters/x.wav")}` and `plain/s3://masters/x.wav`
- **THEN** both yield the same typed source and the same canonical source string

#### Scenario: Malformed sources rejected
- **WHEN** the segment is `plain/ftp://x`, undecodable `enc/…`, or an s3 URL without a key
- **THEN** parsing fails with a structured error

### Requirement: Allowlist enforcement
The system SHALL reject sources whose bucket (S3) or host (HTTP) matches no pattern in `AP_SOURCE_ALLOWLIST`; when the allowlist is unset, HTTP sources SHALL be rejected and S3 sources accepted (private-bucket credentials are the effective gate).

#### Scenario: Allowed bucket
- **WHEN** `AP_SOURCE_ALLOWLIST=masters,previews-*` and the source bucket is `masters`
- **THEN** resolution succeeds

#### Scenario: Wildcard pattern
- **WHEN** the allowlist contains `previews-*` and the bucket is `previews-eu`
- **THEN** resolution succeeds

#### Scenario: Disallowed host
- **WHEN** the source is `https://evil.example/x.wav` and `evil.example` matches no pattern
- **THEN** resolution fails with an authorization error that the HTTP layer maps to 404

### Requirement: Canonical source identity
The system SHALL produce one canonical string per source for cache-key derivation, independent of which URL encoding (`plain` vs `enc`, escaping variants) the request used.

#### Scenario: Encoding-independent cache identity
- **WHEN** the same source arrives via `plain` and `enc` forms
- **THEN** the canonical strings are byte-identical
