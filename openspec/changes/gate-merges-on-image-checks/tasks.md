## 1. The list

- [ ] 1.1 `docs/development.md`: the required-check set becomes a marked table — the four image checks plus `ffmpeg-arch-parity` and `license-compliance` (both legs) — with `capacity`'s deliberate exclusion recorded rather than implied
- [ ] 1.2 State that the rule is a repo setting, what a fork must do, and that the guard below checks the document rather than the setting

## 2. The guard

- [ ] 2.1 Derive the gating job names from `ci.yml`, expanding each matrix leg the way GitHub names it
- [ ] 2.2 Compare against the marked table via `AudioProxy.MarkedTable`; fail on disagreement in either direction
- [ ] 2.3 Mutate the guard to prove it fails: rename a job, drop a table row, add a leg

## 3. Apply

- [ ] 3.1 Update the branch-protection rule on `main` by hand to match the table (not automatable; the change is not done until this is done)
