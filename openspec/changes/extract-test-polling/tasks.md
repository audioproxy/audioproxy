## 1. Baseline

- [ ] 1.1 Record the current suite runtime, split three ways, as the comparison this refactor is verified against: `mix test`, `mix test --include integration`, and the property files alone (`mix test test/audio_proxy/*_property_test.exs`). The last matters most — the 5 ms polls being unified live inside a property loop
- [ ] 1.2 List the 13 files and their current deadlines before touching anything, so a deadline silently changed during extraction is visible in review rather than in a flake three weeks later

## 2. Extract

- [ ] 2.1 `test/support/eventually.ex` with `wait_until/2` (flunks, message names the exceeded deadline), `eventually?/2` (boolean), `gone_within?/2` and `alive?/1` — the last two written in terms of `eventually?/2`, not as their own loop
- [ ] 2.2 Moduledoc explaining the flunk/boolean split and why the deadline stays a parameter while the interval does not. This is the file's real content; the four functions are trivial
- [ ] 2.3 Replace the copies in the nine `wait_until` files, preserving each file's `@deadline` exactly
- [ ] 2.4 Replace the two `eventually` files — `peaks_endpoint_ffmpeg_test.exs` counts attempts rather than milliseconds (`attempts \\ 40` at 50 ms), so convert to a millisecond deadline and check the arithmetic: 40 × 50 ms is 2 s, not the 60 s its `@deadline` suggests
- [ ] 2.5 Replace `gone_within?`/`alive?` in the four files that have them, including `render_endpoint_stream_test.exs`, whose copy inlines `System.cmd("kill", …)` rather than calling a local `alive?`
- [ ] 2.6 Confirm `mix compile --warnings-as-errors` is clean — an unused private function is the compiler telling you a deletion was missed

## 3. Directive

- [ ] 3.1 Add a **Test support** section to `CLAUDE.md`: what lives in `test/support/`, and the rule that a poll loop is imported rather than written. Place it near *Conventions*, where the typing and cache-key rules already are
- [ ] 3.2 Word it so the next three changes in this stack extend it by adding a row rather than by rewriting the section

## 4. Verify

- [ ] 4.1 `mix test`, `mix test --include integration`, `mix test --only ffmpeg` all green
- [ ] 4.2 Compare the property-suite runtime against 1.1. A visible regression means `semaphore_property_test.exs` passes its own 5 ms interval — the module's default does not move
- [ ] 4.3 Confirm no file still defines a private `wait_until`, `eventually`, `gone_within?` or `alive?`: `grep -rn "defp wait_until\|defp eventually\|defp gone_within?\|defp alive?" test`
- [ ] 4.4 `mix format --check-formatted`
