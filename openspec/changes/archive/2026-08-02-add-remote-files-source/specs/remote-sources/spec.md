## ADDED Requirements

### Requirement: S3 source form
The system SHALL parse a decoded source of the form `s3://{bucket}/{key}` into a typed S3 source whose canonical identity is `s3://{bucket}/{key}` with the key as its raw decoded bytes, and SHALL reject a source missing either the bucket or the key.

#### Scenario: S3 source parses
- **WHEN** the decoded source is `s3://masters/2026/piece-final.wav`
- **THEN** the result is an S3 source with bucket `masters` and key `2026/piece-final.wav`

#### Scenario: Escaped key round-trips
- **WHEN** an S3 key contains a space or a `+` and is percent-escaped in the `plain/` form
- **THEN** the parsed key contains the original unescaped bytes

#### Scenario: Missing half rejected
- **WHEN** the decoded source is `s3://masters` or `s3:///a.wav`
- **THEN** parsing fails with a structured error

### Requirement: HTTPS source form
The system SHALL parse a decoded source that is an `https://` URL into a typed HTTP source, and SHALL reject `http://` URLs and URLs carrying userinfo.

#### Scenario: HTTPS source parses
- **WHEN** the decoded source is `https://media.example/track.wav`
- **THEN** the result is an HTTP source for that URL

#### Scenario: Cleartext refused
- **WHEN** the decoded source is `http://media.example/track.wav`
- **THEN** parsing fails with a structured error naming the scheme

#### Scenario: Embedded credentials refused
- **WHEN** the decoded source is `https://user:pass@media.example/track.wav`
- **THEN** parsing fails with a structured error

### Requirement: HTTPS canonical identity is normalized
The system SHALL fold every spelling of one HTTPS resource onto one canonical string — lowercasing scheme and host, stripping a trailing root dot from the host, rendering an IP literal in its canonical form, dropping the scheme's default port, rendering an absent path as `/`, and discarding an empty query and any fragment — while preserving the URL's own percent-encoding and its dot segments.

#### Scenario: Spellings converge
- **WHEN** `https://Media.Example.:443/a.wav?` and `https://media.example/a.wav` are parsed
- **THEN** both yield byte-identical canonical strings

#### Scenario: IP literal spelling folds
- **WHEN** `https://[0:0:0:0:0:0:0:1]/a.wav` is parsed
- **THEN** the canonical string is `https://[::1]/a.wav`

#### Scenario: The URL's own escaping is preserved
- **WHEN** `https://h/a%2Fb.wav` and `https://h/a/b.wav` are parsed
- **THEN** their canonical strings differ, because the origin may treat them as different objects

#### Scenario: Ambiguous IP shorthand is not folded
- **WHEN** the host is `01.2.3.4`
- **THEN** it is treated as a name rather than rewritten to `1.2.3.4`, so it cannot inherit an allowlist entry naming the canonical address

### Requirement: Allowlist policy for remote sources
The system SHALL reject a remote source whose bucket (S3) or host (HTTPS) matches no pattern in `AP_SOURCE_ALLOWLIST`, and when that variable is unset SHALL accept S3 sources and reject HTTPS sources.

#### Scenario: Bucket prefix glob
- **WHEN** the allowlist contains `previews-*` and the bucket is `previews-eu`
- **THEN** authorization succeeds

#### Scenario: Host suffix glob is label-anchored
- **WHEN** the allowlist contains `*.media.example`
- **THEN** `media.example` and `cdn.media.example` are accepted, and `media.example.evil.com` is rejected

#### Scenario: Host prefix glob is not a pattern
- **WHEN** the allowlist contains `cdn.*` and the host is `cdn.evil.com`
- **THEN** authorization fails, because a host prefix glob would admit any registrable suffix

#### Scenario: Unset allowlist
- **WHEN** `AP_SOURCE_ALLOWLIST` is unset
- **THEN** S3 sources are accepted (bucket credentials are the gate) and HTTPS sources are rejected

#### Scenario: Failure is indistinguishable from absence
- **WHEN** a source fails the allowlist
- **THEN** the error is the same authorization error the HTTP layer maps to 404, with no distinct status revealing that the source exists
