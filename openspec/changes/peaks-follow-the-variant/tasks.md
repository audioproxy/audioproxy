# Tasks

## 1. Decide
- [ ] 1.1 Settle the open question: accept the one-time byte change for `norm` without `sr` under an unchanged cache key, or restrict the fix to the peaks decode. Everything below assumes the former
## 2. Source metadata reaches the builder
- [ ] 2.1 Thread the probe's sample rate and bit depth from `RenderAction` into `Command.build/3`
- [ ] 2.2 `resample/1` targets the source's rate, clamped for lossy formats, 48 kHz fallback documented
- [ ] 2.3 Golden argv for each: source-rate, lossy clamp, unknown-rate fallback, and the bit-depth fallback finally exercised
## 3. Peaks follow the variant
- [ ] 3.1 Drop `gain` and `norm` from the peaks refusal list; restate the rule as "cannot change the picture"
- [ ] 3.2 `:ffmpeg` end-to-end: `f:peaks/gain:-6` and `f:peaks/norm:ebu` move the picture while `samples_per_pixel`, `sample_rate` and `length` stay put
- [ ] 3.3 Frame-count guard: the decode emits what the reducer budgeted, asserted rather than assumed
## 4. Docs
- [ ] 4.1 API doc §3.1/§3.2/§3.3, `llms-full.txt` (guards enforce), `docs/ffmpeg-arguments.md` filter-order note, and the release note the byte change owes
