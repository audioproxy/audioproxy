## ADDED Requirements

### Requirement: Readiness endpoint
The system SHALL serve `GET /ready` unsigned: 200 while the node should receive new work, 503 once queue depth reaches `AP_READY_QUEUE_THRESHOLD`, recovering only after depth falls below a lower hysteresis mark — readiness flaps SHALL NOT track instantaneous depth. `/health` SHALL remain pure liveness, unaffected by load.

#### Scenario: Saturated node signals not-ready
- **WHEN** queue depth reaches the threshold
- **THEN** `/ready` answers 503 while `/health` stays 200

#### Scenario: Hysteresis prevents flapping
- **WHEN** depth oscillates around the threshold
- **THEN** readiness switches at most once per excursion (trip high, recover low)

#### Scenario: Default posture
- **WHEN** `AP_READY_QUEUE_THRESHOLD` is unset
- **THEN** a documented default well below `AP_QUEUE_SIZE` applies, and setting it to `0` disables the check (always ready)
