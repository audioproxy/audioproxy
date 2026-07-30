# processing-options Specification

## Purpose
The options segments are the API. A variant is described entirely by them, so
there is nothing else to consult: no request body, no server-side state, no
per-variant configuration. Their normalized form is hashed directly into the
cache key, which makes this layer the determinism boundary for the whole
proxy — two URLs describing the same variant must produce byte-identical
normalized strings, or the same audio is rendered and stored twice, and two
URLs describing different variants must never converge, or a client receives
audio it did not ask for.

Two rules keep that stable. Decimals are pinned to a millisecond grid at parse
time and rejected beyond it rather than rounded, so float formatting can never
move a cache key. Every number is rendered through a single function, so there
is one spelling of each value rather than one per call site.

Rejection is preferred to silent tolerance throughout: unknown keys, repeated
keys, values a later stage could not render, and options that the requested
format would ignore all fail here, naming the offending segment. An option that
is accepted but ignored still changes the cache key, which is the expensive
kind of mistake — it stores identical output under two names.

Failures are data, not HTTP concerns. This capability knows nothing about
status codes; it names what was wrong and lets the delivery layer render that
as 422.

## Requirements

### Requirement: Options string parses into a typed struct
The system SHALL parse `/`-separated `key:value` segments into typed option values per API doc §3: `f`, `br`, `q`, `sr`, `ch`, `bd`, `t`, `fade`, `gain`, `norm`, `pts`, `pk_fmt`, `dl`, `cb`.

#### Scenario: Full example parses
- **WHEN** parsing `f:opus/br:96/t:12.5:30/fade:0.5:1`
- **THEN** the struct holds format `:opus`, bitrate 96, trim start 12.5 duration 30.0, fade in 0.5 out 1.0

#### Scenario: Multi-value segments
- **WHEN** parsing `t:30` and `t:30:15` and `norm:ebu:-14:-1:9`
- **THEN** optional positional sub-values parse with documented defaults for the omitted ones

### Requirement: Invalid options are rejected with structured errors
The system SHALL reject unknown keys, out-of-domain values, and conflicting combinations with a structured error naming the offending segment; the HTTP layer maps these to 422.

#### Scenario: Unknown key
- **WHEN** parsing `xyz:1`
- **THEN** parsing fails identifying `xyz` as unknown

#### Scenario: Conflicting bitrate and quality
- **WHEN** both `br:128` and `q:5` are present
- **THEN** parsing fails as a conflict (§3.1: mutually exclusive)

#### Scenario: Domain violations
- **WHEN** parsing `ch:3`, or `bd:24` with lossy `f:mp3`, or negative `t` start, or `pts:0`
- **THEN** each fails with a structured domain error

#### Scenario: Values above their upper bound
- **WHEN** parsing `br:10001`, `sr:384001`, `pts:100001`, or `gain:100.001`
- **THEN** each fails as out of range, so an unrenderable value cannot reach a later stage

#### Scenario: Control characters in opaque values
- **WHEN** parsing `dl:` or `cb:` with a value containing a control character (e.g. `cb:a\nb`)
- **THEN** parsing fails, so a normalized options string can never contain one

### Requirement: Peaks reject options they would ignore
Because peaks are computed from the decoded source, the system SHALL reject encoding and loudness options under `f:peaks` (§3.3: peaks respect `t` and `ch` and ignore encoding options) rather than accepting options that cannot affect the output, which would give byte-identical peaks two cache keys.

#### Scenario: Encoding option with peaks
- **WHEN** parsing `f:peaks/br:96`, `f:peaks/q:5`, `f:peaks/sr:48000`, or `f:peaks/bd:16`
- **THEN** each fails with a structured error naming the offending segment

#### Scenario: Loudness option with peaks
- **WHEN** parsing `f:peaks/gain:-3` or `f:peaks/norm:ebu`
- **THEN** each fails with a structured error naming the offending segment

#### Scenario: Options peaks do respect
- **WHEN** parsing `f:peaks/t:10:5/ch:1/pts:2000/pk_fmt:dat`
- **THEN** parsing succeeds

### Requirement: Normalization is canonical and order-insensitive
The system SHALL normalize parsed options such that any two option strings describing the same variant produce identical normalized forms, with defaults (`f:mp3`, `pts:800`, norm targets `-16:-1.5:11`) made explicit.

#### Scenario: Order insensitivity
- **WHEN** parsing `f:opus/br:96` and `br:96/f:opus`
- **THEN** both normalize to the identical canonical form

#### Scenario: Idempotence
- **WHEN** a normalized options string is parsed and normalized again
- **THEN** the result is byte-identical

### Requirement: Cache key derivation
The system SHALL derive the cache key deterministically from the normalized options plus the resolved source identity, such that equal variants share a key and any differing option (including `cb`) yields a different key.

#### Scenario: Same variant, same key
- **WHEN** two requests use differently-ordered but equivalent options for the same source
- **THEN** their cache keys are identical

#### Scenario: Cache-buster changes key
- **WHEN** `cb:v2` is added to an options string
- **THEN** the cache key differs from the same options without `cb`
