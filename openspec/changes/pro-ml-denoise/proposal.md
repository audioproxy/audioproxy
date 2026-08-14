# PRO: ML Denoise (enhance:studio)

## Why

`add-enhance-preset` (OSS) gives `enhance:voice`, a curated conventional chain. The step above it - meaningful suppression of real-world background noise - is an ML model, and ffmpeg ships the seam: `arnndn` runs RNNoise-family models natively. Small models (tens of KB, BSD-licensed), CPU-real-time, no inference sidecar, no GPU. That is the PRO tier; Descript-parity heavy enhancement is explicitly rejected as out of scope - it would mean a separate inference runtime for marginal gain on preview-grade audio.

## What Changes

- `enhance:studio` (PRO): the voice chain with `arnndn` denoising in front, model file shipped in the PRO image.
- **Preset pinning rule inherited from OSS**: `studio` maps to a pinned chain + pinned model; improving either mints `studio2`, because a changed chain under an unchanged option value would change bytes behind an immutable cache key.
- Model licensing and provenance recorded in the image manifest like every other shipped artifact.

## Non-goals

- Descript/DeepFilterNet-class enhancement (rejected, not deferred); user-supplied models; per-knob EQ exposure.

## Capabilities

### New Capabilities
- `pro-audio-enhance`: the PRO enhance vocabulary (`studio`), model shipping, pinning rule.

### Modified Capabilities
<!-- none -->

## Impact

- Depends on: `add-enhance-preset` (OSS - the `enhance` option and pinning rule exist there).
- Tests: golden argv incl. model path; rendered SNR improvement on a noisy fixture vs `voice`; cache-key distinctness of voice/studio.
- Estimated ~200 LOC + model artifact.
