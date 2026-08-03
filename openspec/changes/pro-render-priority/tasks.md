## 1. Warm payload priority

- [ ] 1.1 `priority` per entry and per batch (entry wins); unknown value → that entry `invalid`; plumb class into the coordinator's acquire
- [ ] 1.2 Tests: episode-jumps-backfill end-to-end (fake pipeline); default normal; evicted entries reported `rejected` and retryable; live GET admitted ahead of `high` warms

## 2. Docs

- [ ] 2.1 README (PRO) + `docs/`: priority semantics table, starvation-is-the-contract note, eviction policy, per-class telemetry; interactive-priority open question recorded
