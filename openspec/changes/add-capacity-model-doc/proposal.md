## Why

Operators sizing a deployment need worst-case RAM as arithmetic, not folklore — and a prospective user's workload is long-form audio (1–2 h episodes), which is exactly where the architecture's dominant memory term (the coalescing backlog, now merged with its byte cap) stops being negligible and becomes a capacity decision. The model is derivable from the design; this slice writes it down with *measured* constants and guards it against drift the way this project guards documentation: with CI.

## What Changes

- `docs/capacity.md`: the worst-case model —
  `RAM ≈ BEAM_base + C × (R_ffmpeg + B_backlog + H_pipeline) + U × part_size` (C = `AP_MAX_CONCURRENCY`, U = in-flight S3 write-backs, zero for `file://` stores) — with each term mapped to its configuration knob and its architectural source.
- A **measured `R_ffmpeg` table**: peak subprocess RSS per output format (and `norm`, the heaviest filter) from the pinned ffmpeg on the runtime image — measured, not guessed.
- A **long-form section** with worked examples: a 2 h episode is ~115 MB as mp3 128k / ~86 MB as opus 96k (16 concurrent ≈ 1.8 GB of backlog — feasible, but a decision); lossless full-length (~0.7–1.3 GB each) cannot live in a backlog, and the cap fails it loudly by design. The disk-spooled-backlog escalation is named as the on-demand future change for long-form-primary deployments.
- The two counterintuitive facts stated plainly: **input never accumulates** (ffmpeg streams through fixed buffers; sources are never held — there is no source-size term), and **coalesced subscribers share bytes** (refc binaries: N clients of one variant cost one backlog, not N).
- A **CI drift guard**: a workload job on the built image (concurrent renders incl. a long-form fixture) asserting cgroup `memory.peak` stays under the model's prediction — accounting for reclaimable page cache, which `memory.peak` includes and local-source workloads inflate harmlessly.

## Capabilities

### New Capabilities

- `capacity-model`: The published worst-case memory model and its CI enforcement.

### Modified Capabilities

<!-- none -->

## Impact

- New: `docs/capacity.md`, a measurement script (Ruby, per convention), a CI workload job.
- Depends on: `add-variant-cache` (the last term to exist); coalescing and its backlog cap are already merged.
- Position: directly after `add-variant-cache`; README links the doc from the configuration section.
