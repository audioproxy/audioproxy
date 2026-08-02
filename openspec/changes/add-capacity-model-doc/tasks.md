## 1. Measurement

- [ ] 1.1 Ruby measurement script (runs inside the image): cgroup-scoped peak RSS per render, matrix formats × {plain, `norm`}, 1–2 h lavfi fixtures included; committed output table
- [ ] 1.2 Verify the pipeline high-water and backlog-cap constants referenced by the doc against the merged implementation (read the code, not the old design docs)

## 2. The document

- [ ] 2.1 `docs/capacity.md`: formula with per-term knob/source mapping; measured table; long-form worked examples (lossy feasible + quantified, lossless fails the cap loudly, spool escalation named); input-never-accumulates and refc-sharing sections; page-cache caveat; era/version banner
- [ ] 2.2 README: link from the configuration section; docker upgrade procedure gains "regenerate the RSS table" step

## 3. CI drift guard

- [ ] 3.1 Workload job on the built image: concurrent renders incl. long-form fixture; assert `memory.peak` − inactive-file ≤ model prediction × stated headroom factor
- [ ] 3.2 Red-path check on a scratch branch: an artificially inflated retention (test-only) trips the guard
