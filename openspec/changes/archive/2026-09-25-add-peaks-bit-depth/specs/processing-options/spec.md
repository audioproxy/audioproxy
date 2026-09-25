## ADDED Requirements

### Requirement: Peaks bit depth option
The system SHALL accept `pk_bits` with the values `8` and `16` under `f:peaks`, defaulting to `16`, and SHALL materialize the default into the cache key the way `ch` is materialized, so a URL that omits the segment and one that states the default resolve to one key rather than two.

`pk_bits` exists because peaks.js refuses waveform data that is not 8-bit, and audiowaveform's own instructions for that library are to generate it with `-b 8`. It is peaks-scoped rather than an extension of `bd`: `bd` names the sample format of encoded output and has no meaning for a serialization that is never encoded, so one segment would otherwise mean two different things depending on the format beside it.

#### Scenario: Both values parse
- **WHEN** parsing `f:peaks/pk_bits:8` or `f:peaks/pk_bits:16`
- **THEN** parsing succeeds and the struct carries the width

#### Scenario: The default is materialized
- **WHEN** `f:peaks/pts:800` and `f:peaks/pts:800/pk_bits:16` are normalized
- **THEN** both produce the same cache key

#### Scenario: Any other value is refused
- **WHEN** parsing `f:peaks/pk_bits:24`, `f:peaks/pk_bits:0` or `f:peaks/pk_bits:x`
- **THEN** each fails with a structured error naming the segment

#### Scenario: The option is meaningless outside peaks
- **WHEN** parsing `f:mp3/pk_bits:8` or `f:wav/pk_bits:16`
- **THEN** each fails with a structured error naming the segment, for the same reason encoding options are refused under `f:peaks`: an option that cannot change the output would give byte-identical output two cache keys

## MODIFIED Requirements

### Requirement: Options string parses into a typed struct
The system SHALL parse `/`-separated `key:value` segments into typed option values per API doc §3: `f`, `br`, `q`, `sr`, `ch`, `bd`, `t`, `fade`, `gain`, `norm`, `pts`, `pk_fmt`, `pk_bits`, `dl`, `cb`.

#### Scenario: Full example parses
- **WHEN** parsing `f:opus/br:96/t:12.5:30/fade:0.5:1`
- **THEN** the struct holds format `:opus`, bitrate 96, trim start 12.5 duration 30.0, fade in 0.5 out 1.0

#### Scenario: Multi-value segments
- **WHEN** parsing `t:30` and `t:30:15` and `norm:ebu:-14:-1:9`
- **THEN** optional positional sub-values parse with documented defaults for the omitted ones

### Requirement: Peaks reject options they would ignore
Because peaks are computed from the decoded source, the system SHALL reject options that cannot change the reduction under `f:peaks` — the encoding settings `br`, `q`, `bd` and `sr` — rather than accepting options that cannot affect the output, which would give byte-identical peaks two cache keys.

Options that change the decoded samples SHALL be accepted, because a waveform is drawn under the audio a listener hears: `t`, `ch`, `fade`, `gain`, `norm` and `enhance` all reach the reduction. `sr` is refused despite changing a decode, because bucket boundaries are a fraction of the total sample count rather than of a duration, so it cannot move a pixel.

#### Scenario: Encoding option with peaks
- **WHEN** parsing `f:peaks/br:96`, `f:peaks/q:5`, `f:peaks/sr:48000`, or `f:peaks/bd:16`
- **THEN** each fails with a structured error naming the offending segment

#### Scenario: Loudness options reach the reduction
- **WHEN** parsing `f:peaks/gain:-3` or `f:peaks/norm:ebu`
- **THEN** each parses, because both change the samples the picture is drawn from

#### Scenario: Options peaks do respect
- **WHEN** parsing `f:peaks/t:10:5/ch:1/pts:2000/pk_fmt:dat/pk_bits:8`
- **THEN** parsing succeeds
