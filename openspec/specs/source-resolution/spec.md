# source-resolution Specification

## Purpose
The source segment says *what* to render, and it is the half of a variant's
identity that the processing options do not cover. This layer owns only what
the two encodings imply — resolving `plain/` and `enc/` to one source string,
decoding it exactly once, refusing what no source should carry, and handing
the remainder to whichever source type claims the scheme. What a source *is*
belongs to those types, and each ships in its own slice.

Two invariants make the rest of the proxy safe. Decoding happens exactly
once and before any interpretation, so a confinement check or a URL parse
never runs on a half-decoded string. And both encodings of one source
produce byte-identical canonical strings, so a variant has one cache key
however its URL was spelled.

## Requirements

### Requirement: Source segment encodings
The system SHALL accept the source segment in two encodings — `plain/{source}`, percent-escaped and unescaped exactly once, and `enc/{base64url(source)}`, padded or unpadded — and SHALL resolve both to the same decoded source string before any source-type-specific parsing runs.

#### Scenario: Encodings converge
- **WHEN** one source arrives as `plain/` and as `enc/`
- **THEN** both yield the same typed source and byte-identical canonical strings

#### Scenario: Escaped bytes round-trip
- **WHEN** a `plain/` payload contains `%20`, `%25` or `+`
- **THEN** the decoded source contains a space, a literal `%`, and a literal `+` respectively

#### Scenario: Malformed escape rejected
- **WHEN** a `plain/` payload contains a `%` not followed by two hex digits
- **THEN** parsing fails with a structured error, rather than passing the bytes through and giving one source two spellings

#### Scenario: Undecodable encoded payload rejected
- **WHEN** an `enc/` payload is not valid base64url, or decodes to bytes that are not valid UTF-8
- **THEN** parsing fails with a structured error

#### Scenario: Unknown encoding prefix rejected
- **WHEN** the segment begins with neither `plain/` nor `enc/`
- **THEN** parsing fails with a structured error

### Requirement: Universally rejected content
The system SHALL reject a decoded source containing any Unicode control, format, or line/paragraph-separator code point, regardless of source type.

#### Scenario: ASCII control rejected
- **WHEN** the decoded source contains a NUL byte or a newline
- **THEN** parsing fails with a structured error

#### Scenario: Non-ASCII control rejected
- **WHEN** the decoded source contains U+0085, U+2028, or a right-to-left override
- **THEN** parsing fails with a structured error, because such a code point would reach ffmpeg arguments, object keys and log lines

#### Scenario: Ordinary non-ASCII text accepted
- **WHEN** the decoded source contains accented or non-Latin characters
- **THEN** parsing succeeds — only control-class code points are refused

### Requirement: Source types dispatch by scheme
The system SHALL split the decoded source on its scheme, match the scheme case-insensitively against the registered source types, and delegate parsing to the matching type; a scheme with no registered type SHALL fail with a structured error.

#### Scenario: Registered scheme dispatches
- **WHEN** a type is registered for scheme `x` and the decoded source is `x://body`
- **THEN** that type's parser receives `body` and its result is returned

#### Scenario: Scheme case is insensitive
- **WHEN** the decoded source spells a registered scheme in mixed case
- **THEN** it dispatches to the same type

#### Scenario: Unregistered scheme rejected
- **WHEN** the decoded source names a scheme no type is registered for, or carries no scheme at all
- **THEN** parsing fails with a structured error

#### Scenario: No types registered
- **WHEN** no source types are registered
- **THEN** every source fails with the unregistered-scheme error, and nothing else in the pipeline changes behavior

### Requirement: Source type contract
The system SHALL define a source-type contract covering parsing a decoded body into a typed source, rendering that source's canonical identity, authorizing it, and the storage operations the render and info flows need — metadata (size and ETag material) and an ffmpeg input.

#### Scenario: Authorization is delegated
- **WHEN** a typed source is authorized
- **THEN** the decision comes from its own type, so an allowlist, a filesystem root, or any other policy can gate its own kind without the shared layer knowing what gating means

#### Scenario: Storage is delegated
- **WHEN** the render or info flow asks a source for its metadata or its ffmpeg input
- **THEN** the answer comes from its own type, so a later backend is a registration rather than a change to those flows

### Requirement: Canonical source identity
The system SHALL produce one canonical string per source for cache-key derivation, independent of which encoding the request used.

#### Scenario: Encoding-independent cache identity
- **WHEN** the same source arrives via `plain` and `enc` forms
- **THEN** the canonical strings are byte-identical, and therefore so are the cache keys derived from them
