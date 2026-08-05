# source-info Specification

## Purpose
Answer what a source *is*, so a client can size a request to the file before
making one. `GET /{sig}/info/{source}` runs `ffprobe` and filters its verbose,
version-dependent output down to one stable JSON object: format, duration,
sample rate, channels, bit depth, bitrate, size and tags. It shares the whole
check chain with the render endpoint and diverges only at the action, so the
signature gate, the source resolution and the blind 404 are the same ones.
Cheap by construction — a probe reads container headers and never decodes —
which is why it is bounded by its own short `AP_PROBE_TIMEOUT` rather than by
the render budget, and why neither the concurrency cap nor the source size
limit applies to it.

## Requirements
### Requirement: Probe metadata as JSON
The system SHALL serve `GET /{sig}/info/{source}` returning the §4 JSON object — `format`, `duration` (seconds, float), `sample_rate`, `channels`, `bit_depth` (when applicable), `bitrate`, `size`, `tags` — derived from ffprobe and filtered to that contract.

#### Scenario: WAV fixture probed
- **WHEN** info is requested for a generated 48 kHz stereo 16-bit WAV of known duration
- **THEN** the JSON reports format `wav`, the expected duration (±0.1 s), 48000, 2, 16, and the object size

#### Scenario: Lossy source omits bit depth
- **WHEN** info is requested for an mp3 source
- **THEN** `bit_depth` is absent and `bitrate` is populated

#### Scenario: Tags passthrough
- **WHEN** the source carries title/artist tags
- **THEN** they appear under `tags`

### Requirement: Unknown fields are omitted, never null
The system SHALL omit any contract field ffprobe cannot answer, rather than emitting `null` or a zero standing in for "unknown", so that testing for a key is a true answer for every source. Tag values SHALL be string-valued entries only, with keys lowercased and both the count and the length of the block capped.

#### Scenario: Field ffprobe reports as N/A
- **WHEN** ffprobe reports a field as `N/A` in one section and a usable value in another
- **THEN** the fallback is taken from the usable section, and a field no section answers is absent from the object entirely

#### Scenario: Source with no audio stream
- **WHEN** info is requested for a container ffprobe parses but that carries no audio stream
- **THEN** the response is 415, not an object with every field missing

### Requirement: Format is reported in the API's own vocabulary
The system SHALL report `format` as the §3.1 token a client would pass back where the container has one — the MP4 family as `m4a`, Ogg as `opus` or `ogg` according to its codec — matching on membership of ffprobe's comma-separated demuxer list rather than on the whole string, since that list's contents and order are ffprobe's own business. A container §3.1 has no token for SHALL be named plainly rather than forced into one.

#### Scenario: Demuxer list reordered between ffmpeg versions
- **WHEN** ffprobe names the MP4 family with any ordering or superset of `mov,mp4,m4a,3gp,3g2,mj2`
- **THEN** the reported format is `m4a`

#### Scenario: Container the API cannot emit
- **WHEN** the source is in a container with no §3.1 token, such as `matroska,webm`
- **THEN** the reported format is the container's own first name

### Requirement: Options are rejected on info requests
The system SHALL reject processing options combined with `info` (422) — info takes no processing options per §2.

#### Scenario: Options with info
- **WHEN** requesting `/{sig}/info/br:128/{source}`
- **THEN** the response is 422

#### Scenario: Order does not change the verdict
- **WHEN** `info` appears before or after another option segment
- **THEN** the response is 422 either way, naming the segment that cannot accompany it, and the chain halts before the source is resolved

### Requirement: Info responses are cacheable
The system SHALL emit a strong `ETag` derived from the source's canonical identity and the storage backend's ETag material, and answer `If-None-Match` with 304 after the source stat and before any probe. `Cache-Control` SHALL be `public, max-age=3600` and SHALL NOT be `immutable`: the URL describes a mutable source, so a cache that never revalidates could never be corrected. A backend offering no ETag material SHALL receive no validator and a shorter `public, max-age=60`.

#### Scenario: Conditional revalidation
- **WHEN** a client repeats the request with the previous `ETag` in `If-None-Match`
- **THEN** the response is 304 with no body, and no probe runs

#### Scenario: Source replaced
- **WHEN** the source object changes
- **THEN** the emitted `ETag` changes with it

### Requirement: Probe failures map to the error contract
The system SHALL return 404 for unreadable/missing sources and 415 for sources ffprobe cannot parse.

#### Scenario: Unprobeable source
- **WHEN** info is requested for a text file
- **THEN** the response is 415 with a JSON error

#### Scenario: Probe timeout
- **WHEN** a probe exceeds `AP_PROBE_TIMEOUT`
- **THEN** the response is 504 with `probe_timeout`, distinct from the render path's `render_timeout` so the body names the limit an operator would raise

### Requirement: Source size does not limit description
The system SHALL describe a source of any size, and SHALL NOT apply `AP_MAX_SRC_BYTES` to info requests — a probe reads container headers rather than decoding, so the render path's byte limit buys nothing here and would withhold exactly the numbers a client needs in order to request a bounded variant of a long source.

#### Scenario: Source larger than the render limit
- **WHEN** info is requested for a source exceeding `AP_MAX_SRC_BYTES`
- **THEN** the response is 200 with the full contract, while a render of the same source is still 413
