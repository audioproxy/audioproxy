## ADDED Requirements

### Requirement: The pre-render probe is shared per source
The system SHALL run at most one source probe per in-flight source. Concurrent requests reading the same source SHALL await one probe's verdict rather than each spawning their own.

The identity SHALL be the canonical source rather than the cache key renders coalesce on. A probe reads container headers, so its verdict depends on the source and on nothing else: two variants of one file ask `ffprobe` the identical question about the identical bytes. Keying on the source is therefore a superset of keying on the variant, and it is what lets `/info` — which describes no variant, and so has no cache key — share the mechanism with the render endpoint's gate.

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

#### Scenario: Different variants of one source share the probe
- **WHEN** concurrent requests name different variants of the same not-yet-cached source
- **THEN** exactly one `ffprobe` process is spawned, even though the renders that follow do not coalesce

#### Scenario: `/info` and the render gate share the probe
- **WHEN** an `/info` request and a render request for the same source are in flight together
- **THEN** exactly one `ffprobe` process is spawned, and both are answered from it
