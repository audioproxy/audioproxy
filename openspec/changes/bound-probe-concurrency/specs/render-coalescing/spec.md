## ADDED Requirements

### Requirement: The pre-render probe is shared per cache key
The system SHALL run at most one source probe per in-flight cache key. Concurrent requests describing the same variant SHALL await one probe's verdict rather than each spawning their own, on the same deduplication identity renders already coalesce on.

#### Scenario: Concurrent requests for one variant probe once
- **WHEN** several concurrent requests for the same not-yet-cached variant reach the audio-only gate
- **THEN** exactly one `ffprobe` process is spawned, and every request is answered from its verdict

#### Scenario: A refusal is shared too
- **WHEN** the shared probe finds video
- **THEN** every waiting request answers 415, and no render is started for any of them

#### Scenario: A failed probe fails its waiters alike
- **WHEN** the shared probe times out, dies, or cannot parse the source
- **THEN** every waiting request answers the class that probe reported, and no entry is left behind for the next request to attach to

#### Scenario: A late request does not re-probe needlessly
- **WHEN** a request arrives while a probe's verdict is still held
- **THEN** it is answered from that verdict without a second spawn
