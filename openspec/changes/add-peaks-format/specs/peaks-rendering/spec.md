## ADDED Requirements

### Requirement: Peaks are computed from decoded audio
The system SHALL render `f:peaks` by decoding the source (respecting `t` trim and `ch` downmix, ignoring encoding options) and reducing samples to `pts` min/max pairs (default 800) spanning the selected region evenly.

#### Scenario: Known signal shape
- **WHEN** peaks are rendered for a generated 1 kHz full-scale sine
- **THEN** min values approach -1.0 and max values approach +1.0 uniformly across buckets (within codec tolerance)

#### Scenario: Silence detected
- **WHEN** peaks are rendered for a silent region
- **THEN** the corresponding pairs are ~0

#### Scenario: Trim respected
- **WHEN** peaks are rendered with `t:1:1` over a fixture that is silent in exactly that window
- **THEN** all pairs are ~0 even though the rest of the file is loud

#### Scenario: Encoding options ignored
- **WHEN** `br` or `sr` accompany `f:peaks`
- **THEN** options validation rejects the request (422) per §3.3's option gating

### Requirement: JSON peaks output
The system SHALL serve `pk_fmt:json` (default) as an audiowaveform-compatible JSON object: `version`, `channels`, `sample_rate`, `samples_per_pixel`, `bits`, `length`, and interleaved min/max integer `data`.

#### Scenario: Schema shape
- **WHEN** a JSON peaks response is decoded
- **THEN** all listed fields are present, `length == pts`, and `data` holds `length × 2 × channels` integers within the `bits` range

### Requirement: Binary peaks output
The system SHALL serve `pk_fmt:dat` as the compact binary format (audiowaveform .dat layout: little-endian header with version/flags/sample rate/samples-per-pixel/length, then int8 or int16 min/max pairs).

#### Scenario: Round-trip consistency
- **WHEN** the same variant is rendered as `json` and `dat`
- **THEN** decoding the binary yields the same pair values as the JSON `data`

### Requirement: Peaks participate in caching
The system SHALL cache peaks variants exactly like audio variants (cache key, write-back, HIT redirect) with `Content-Type: application/json` or `application/octet-stream`.

#### Scenario: Peaks HIT
- **WHEN** the same peaks URL is requested twice with the variant bucket configured
- **THEN** the second response is a HIT without decoding
