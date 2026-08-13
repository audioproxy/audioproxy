## 1. The guard

- [x] 1.1 `AudioProxy.ConfigHelper.validate_keys!/2` — takes the override map and the name of the calling helper, raises `ArgumentError` naming the unknown key and the caller. Derives its set from `Map.keys(AudioProxy.Config.build!(%{}))`, and the `:s3` sub-map's from `build!(%{}).s3`
- [x] 1.2 Nearest-key suggestion via `String.jaro_distance/2`, reported only above 0.8. Below it, name the unknown key and stop — a wrong suggestion is worse than none
- [x] 1.3 Doc the *reason* on the function, not just the behaviour: the floor stops the environment from changing what a test asserts, and this stops a typo from doing the same. That sentence is why the function exists

## 2. Wiring

- [x] 2.1 `put_config/1` calls it. This is the chokepoint — 127 of the suite's 150 config overrides pass through here
- [x] 2.2 `SignedRequest.base_config/1` calls it too, before merging, so the error names the call site that wrote the override rather than the `put_config` below it
- [x] 2.3 Run the full suite. **A rejection is a finding, not a false positive** — the key names something nothing reads. Fix each one here; if any turns out to need a key `AudioProxy.Config` does not define, stop and raise it rather than widening the guard

## 3. Tests

- [x] 3.1 `test/audio_proxy/config_helper_test.exs` (or the existing support test file): an unknown key raises and the message names it; a known key merges unchanged; a nested `s3` typo is caught; a real `s3` key is not
- [x] 3.2 One test pinning the suggestion: `probe_timout` suggests `probe_timeout`. Assert the suggestion appears, not the exact sentence — the wording will be edited and the test should not break when it is
- [x] 3.3 A test that the set is derived, not restated: every key of `AudioProxy.Config.build!(%{})` is accepted. It fails the day someone hard-codes a list

## 4. Docs

- [x] 4.1 `CLAUDE.md` *Test support* — a line under the `base_config/1` rules saying a mistyped override is refused, and that the key set comes from `Config` so a new setting needs no support-layer edit

## 5. Verify

- [x] 5.1 `mix test`, `mix test --include integration`, `mix test --only ffmpeg`
- [x] 5.2 `mix compile --warnings-as-errors` and `mix format --check-formatted`
- [x] 5.3 Confirm no `lib/` file changed: `git diff --name-only main...HEAD -- lib` is empty. If it is not, the design decision moved and `design.md` has to say why
