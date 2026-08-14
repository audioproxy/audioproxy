# Peaks Follow the Variant (`gain`, `norm`, and the source's rate)

## Why

A waveform is drawn under a player, and the player plays a *variant*. So the picture should describe the audio a listener hears. `f:peaks` half does: `t`, `ch`, `fade` and (since `add-enhance-preset`) `enhance` all apply, while `gain` and `norm` are refused with a `422`.

The stated reason for the refusals does not cover them. It is that an option which cannot change the output would hand identical bytes two cache keys — true of `br`, `q` and `bd`, which cannot move a pixel, and false of `gain` and `norm`, which move every pixel. A player that normalizes and a waveform that does not is the defect this closes.

`gain` is a one-line change. `norm` is not, and the reason is the second half of this proposal.

**Single-pass `loudnorm` re-rates the decode.** The builder appends `aresample=48000` after `loudnorm` when no `sr` was given, while `AudioProxy.Peaks.Render` budgets its buckets from `duration × the source's probed rate`. Measured on one 5 s 44.1 kHz source: the reducer budgets 220500 frames and the decode emits 240000. That is not an error anybody sees — the reducer folds an overrun into its final bucket by design, for a frame or two of container-header slop — so `norm` would ship a waveform ending in a fake spike over a header still claiming 44100. Silently wrong is worse than refused.

**The fix belongs on the audio path anyway, because that 48 kHz is a contract violation.** §3.1 says an absent `sr` means "follow the source's rate". `norm:ebu` on a 44.1 kHz source returns 48 kHz, and on a 96 kHz master it silently downsamples. `AudioProxy.Ffmpeg.Command`'s own moduledoc records this as a known defect and names the blocker: "Fixing that needs the source's real rate, which this module deliberately does not know."

That blocker is stale. The audio-only gate runs `ffprobe` on every MISS and its result sits in `AudioProxy.Plugs.RenderAction`; the call site simply passes `type: type` and nothing else. `Command`'s `source` keyword already exists and already documents `:bit_depth` for exactly this purpose — and *that* feature is dormant for the same reason, so a lossless variant still falls back to 16-bit instead of following the source. **Two documented "follows the source" behaviours are inert, waiting on one piece of plumbing that is already probed for.**

Thread the probe into `build/3` and the peaks question stops needing a peaks-specific answer: the decode keeps the source's rate, the reducer's existing budget is correct by construction, and `f:wav` on a 24-bit master stops returning 16-bit.

## What Changes

- **`gain` and `norm` become valid under `f:peaks`**, joining `t`, `ch`, `fade` and `enhance`. `br`, `q`, `bd` and `sr` stay refused — they genuinely cannot change the picture. The refusal list's comment stops claiming a rule it does not follow.
- **The probe's metadata reaches the argv builder.** `RenderAction` passes the source's sample rate and bit depth into `Command.build/3` alongside `type`.
- **A normalized render follows the source's rate** rather than 48 kHz, clamped to the §3.1 lossy cap for lossy formats and falling back to 48 kHz — documented, not silent — when no probe ran.
- **The dormant bit-depth fallback comes alive** as a consequence: with no `bd`, a lossless variant follows the source's depth, as §3.1 already promises.

## Capabilities

### New Capabilities
<!-- none -->

### Modified Capabilities
- `processing-options`: `gain` and `norm` are no longer refused under `f:peaks`, and the refusal rule is restated as "cannot change the picture".
- `ffmpeg-args`: the post-`loudnorm` resample target, and the source metadata the builder is given.
- `peaks-rendering`: the reduction reflects every option that changes the samples.

## Impact

- Modified: `AudioProxy.Options` (refusal list), `AudioProxy.Ffmpeg.Command` (`resample/1`, `t:source/0`), `AudioProxy.Plugs.RenderAction` (thread the probe), docs per the docs-shape table.
- Tests: `f:peaks/norm:ebu` and `f:peaks/gain:-6` end to end, asserting the picture moves *and* `samples_per_pixel`/`sample_rate`/`length` stay put; a normalized render keeping 44.1 kHz and a 96 kHz master not being downsampled; the lossless depth fallback finally exercised against a real probe.
- Estimated ~250 LOC. No new dependencies.

## Decisions

- **The one-time byte change is accepted, because there is nothing warm to break.** `norm` without `sr` currently returns 48 kHz and will return the source's rate, which changes bytes under an unchanged cache key — normally the hazard `add-enhance-preset` spent its whole review on, since a warm CDN would keep serving the old bytes while a cold cache produced the new ones. It does not apply here: there are no third-party deployments, and the only known instance is this project's own playground, whose variant store can be purged. So the fix goes in the argv where it belongs, rather than being confined to the peaks decode.

  **Two things follow, and they are the cost of the decision rather than footnotes.** Purging the playground's variant store is part of the release, not an afterthought — a stale 48 kHz variant there is a demo that contradicts the documentation. And this window closes: the same change after the first real deployment would need a cache-busting story, so if this change is still unimplemented by then, reopen this decision rather than inheriting it.

## Open questions

- Whether `sr` should also become valid under `f:peaks`. It cannot change the *picture* — bucket boundaries are a fraction of the total sample count — but it does change the `sample_rate` and `samples_per_pixel` a consumer reads. Currently refused; leaving it refused is defensible, and saying so explicitly is better than the silence today.
