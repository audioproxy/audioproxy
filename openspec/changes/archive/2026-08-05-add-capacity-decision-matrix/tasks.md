## 1. The generator

- [x] 1.1 Emit the concurrency matrix (`C_max` over length × codec/bitrate × container memory) from the published formula and the committed `R_ffmpeg` table, sharing `BEAM_base`, `T_ffmpeg`, `H_pipeline` and `LINGER_BACKLOGS` with `bin/check-capacity` rather than restating them
- [x] 1.2 Floor the division, subtract the linger term, and mark cells whose single-render backlog exceeds `AP_MAX_SRC_BYTES` as refused
- [x] 1.3 Emit the reverse table: RAM required for a chosen concurrency
- [x] 1.4 Write both between markers in `docs/capacity.md`, the way `bin/measure-ffmpeg-rss --write` already does

## 2. The restructure

- [x] 2.1 Move the matrix to the top of `docs/capacity.md`, directly after the version banner; demote the formula, term table, measured table and worked examples to the derivation below it
- [x] 2.2 Caveat the matrix in one line (worst-case simultaneity; the column is the container's limit, not the machine's) and state that it is a memory bound, not a throughput one
- [x] 2.3 Section on the knobs deliberately absent: `AP_QUEUE_SIZE` (no meaningful memory), `AP_MAX_SRC_BYTES` (per-render ceiling, not a total)
- [x] 2.4 Re-point the README's sizing paragraph at the matrix rather than the formula

## 3. Keeping it true

- [x] 3.1 Spot-check generated cells against `bin/check-capacity`'s prediction for the same configuration — the two compute the same model and must agree
- [x] 3.2 Add matrix regeneration to the pin-bump procedure in `VERSIONS.md`, alongside the RSS table step
