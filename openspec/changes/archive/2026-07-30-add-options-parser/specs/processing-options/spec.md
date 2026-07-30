## ADDED Requirements

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
