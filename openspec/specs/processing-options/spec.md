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

This extends to combinations that no encoder can honour. Building the ffmpeg argv made three of them visible: `br` on a lossless format and `q` on PCM are accepted by ffmpeg and silently ignored, `bd:32f` on flac fails inside ffmpeg (its encoder takes `s16` and `s32` only), and a fade-out has no start time without a bounded trim to count back from. All four are refused at parse time — the same reasoning as the peaks rule below, since an option that cannot change the output would otherwise give byte-identical output two cache keys.

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

#### Scenario: Encoding option the codec cannot honour
- **WHEN** parsing `f:flac/br:320`, `f:wav/br:320`, or `f:wav/q:8`
- **THEN** each fails with a structured error naming the segment and the format it conflicts with

#### Scenario: Float bit depth outside wav
- **WHEN** parsing `f:flac/bd:32f`
- **THEN** parsing fails, because flac encodes integer samples only

#### Scenario: Peaks report the peaks rule
- **WHEN** any refused option is combined with `f:peaks` (`br`, `q`, `sr`, `bd:16`, `bd:32f`, `gain`, `norm`)
- **THEN** every one reports the peaks rule, not an incidental format rule, so the error names the reason that actually explains the refusal

#### Scenario: Quality on a codec whose scale is compression effort
- **WHEN** parsing `f:opus/q:8` or `f:flac/q:8`
- **THEN** parsing succeeds, and the value maps to that codec's `compression_level`

#### Scenario: Quality outside the codec's scale
- **WHEN** parsing `f:flac/q:13`, `f:mp3/q:10`, `f:opus/q:11`, `f:ogg/q:-2`, or `f:aac/q:5`
- **THEN** each fails as out of range for that format — `q` is a codec-specific number, so its domain is the codec's own scale (mp3 0–9, ogg −1–10, aac/m4a 0.1–2, opus 0–10, flac 0–12)
- **AND** `f:flac/q:13` in particular is refused by ffmpeg itself, so accepting it would turn a 422 into a 500

#### Scenario: Signed zero is collapsed at parse time
- **WHEN** parsing `gain:-0`, `fade:-0`, or `t:-0`
- **THEN** the parsed value is positive zero, so no `-0` spelling can reach the struct and diverge from `0` downstream while normalizing identically to it

#### Scenario: Fade-out without a bounded trim
- **WHEN** parsing `fade:0:2` or `t:1/fade:2:2`
- **THEN** parsing fails, because the fade-out start cannot be computed without a duration

#### Scenario: Fade-in without a trim
- **WHEN** parsing `fade:2`
- **THEN** parsing succeeds, because a fade-in starts at zero

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

### Requirement: Request options are signed but not cache-keyed
The options grammar SHALL distinguish variant options (normalized into the canonical options string, the cache key, and the ffmpeg args) from request options (parsed and validated in the options segment, covered by the signature as path bytes, excluded from the canonical options string, the cache key, and the ffmpeg args), and the round-trip property SHALL hold per class: variant options round-trip to an identical cache key; request options round-trip to the signed path only.

#### Scenario: Differing request options share one variant
- **WHEN** two signed URLs differ only in a request option's value
- **THEN** they produce identical cache keys, identical ffmpeg args, and concurrent requests coalesce into one render

#### Scenario: Request options are tamper-proof
- **WHEN** a request option's value in the path is altered without re-signing
- **THEN** signature verification fails exactly as for any other path byte

### Requirement: exp option
The system SHALL accept `exp:<unix-seconds>` as a request option — a bounded positive integer, duplicates rejected like any duplicate option — whose only semantic is the expiry verdict; it SHALL never influence the rendered bytes, the cache key, or the ffmpeg invocation.

#### Scenario: Past timestamps are valid grammar
- **WHEN** a correctly signed URL carries an `exp` in the past
- **THEN** parsing succeeds and the response is the expiry verdict, not an invalid-option error

#### Scenario: Malformed exp rejected
- **WHEN** `exp` carries a non-integer, a negative value, or exceeds the numeric bounds
- **THEN** the response is the invalid-option error, exactly as for a malformed variant option

### Requirement: enhance preset option
The system SHALL accept `enhance:voice`, applying a pinned conventional enhancement chain (high-pass, denoise, de-ess, compression, peak limiting) with a fixed position in the filter order, orthogonal to `norm:`, and SHALL treat preset values as immutable: a changed chain is a new value, never a mutation of an existing one.

#### Scenario: Preset renders and caches as one variant
- **WHEN** a source renders with `enhance:voice` twice with different option spellings around it
- **THEN** both hit one cache key and the chain's filters appear once in the argv

#### Scenario: Composes with norm
- **WHEN** `enhance:voice/norm:ebu` is requested
- **THEN** both apply, enhancement before loudness normalization

#### Scenario: Pinning survives improvement
- **WHEN** a better chain is found for the job a preset value already names
- **THEN** it is published as a new preset value, and every existing value keeps producing the bytes it always produced

#### Scenario: An unrecognized preset name is refused
- **WHEN** `enhance:` names anything outside the published vocabulary, including a name a future release might mint
- **THEN** the request is refused with `422` naming the segment, so publishing a preset is additive rather than a change of meaning

#### Scenario: Peaks are drawn from the enhanced samples
- **WHEN** `enhance` is combined with `f:peaks`
- **THEN** the preset applies to the decode the waveform is reduced from, as `fade` already does, so the picture describes the audio a listener would hear rather than the unprocessed source
- **AND** the bucket boundaries stay correct, because every filter in the chain preserves the frame count the reducer budgets from the source probe

