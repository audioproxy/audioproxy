# Tasks

## 1. Source metadata reaches the builder
- [ ] 1.1 Thread the probe's sample rate and bit depth from `RenderAction` into `Command.build/3`
- [ ] 1.2 `resample/1` targets the source's rate, clamped for lossy formats, 48 kHz fallback documented
- [ ] 1.3 Golden argv for each: source-rate, lossy clamp, unknown-rate fallback, and the bit-depth fallback finally exercised
## 2. Peaks follow the variant
- [ ] 2.1 Drop `gain` and `norm` from the peaks refusal list; restate the rule as "cannot change the picture"
- [ ] 2.2 `:ffmpeg` end-to-end: `f:peaks/gain:-6` and `f:peaks/norm:ebu` move the picture while `samples_per_pixel`, `sample_rate` and `length` stay put
- [ ] 2.3 Frame-count guard: the decode emits what the reducer budgeted, asserted rather than assumed
## 3. Release
- [ ] 3.1 API doc §3.1/§3.2/§3.3, `llms-full.txt` (guards enforce), `docs/ffmpeg-arguments.md` filter-order note, and the release note the byte change owes
- [ ] 3.2 Purge the playground's variant store on release, so no stale 48 kHz variant outlives the fix
