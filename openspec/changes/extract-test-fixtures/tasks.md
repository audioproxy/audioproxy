## 1. Baseline

- [ ] 1.1 Branch from `main` at or after `extract-signed-request-helper` merges — it is the last of the three this one rebases onto
- [ ] 1.2 Time `mix test --only ffmpeg` and keep the number. The cross-run fixture cache disappears in this change, and 4.3 decides whether that mattered
- [ ] 1.3 **Reproduce the collision before fixing it.** Run `mix test --only ffmpeg` from two worktrees simultaneously and capture the failure. It presents as a codec or duration assertion failing in a test with nothing wrong with it; if it does not reproduce on the first try, run it a few times — it is a race. A fix for a bug nobody has seen fail is a fix nobody can verify
- [ ] 1.4 Clean up any leftovers from the current fixed paths before starting: `rm -rf $TMPDIR/audio_proxy_render_fixtures $TMPDIR/audio_proxy_command_test_tone.wav`

## 2. Extract

- [ ] 2.1 `test/support/fixtures.ex` with `root!/1` (labelled, unique, `rm_rf` on exit), `encode!/3` (lavfi source plus trailing options), and the named helpers `sine/2`, `silence/2`, `video/1`, `tagged_mp3/2`
- [ ] 2.2 `sine/2` takes amplitude explicitly, and the comment explaining why — lavfi's bare `sine` is not full scale, so an inherited amplitude makes the peaks assertions assert a version of ffmpeg — **moves** from `peaks_endpoint_ffmpeg_test.exs` onto it
- [ ] 2.3 Moduledoc records the isolation rule and what it is defending against: parallel worktree runs sharing `System.tmp_dir!()`, and what the failure looked like when it was found (1.3's capture)
- [ ] 2.4 Convert the three files already using unique roots — `info_endpoint_ffmpeg_test.exs`, `render_endpoint_ffmpeg_test.exs`, `peaks_endpoint_ffmpeg_test.exs` — keeping each file's fixture *list* and its comments in place
- [ ] 2.5 Convert `command_ffmpeg_test.exs` to a unique root, dropping the `unless File.exists?` cache and the `on_exit(File.rm)` that fought it

## 3. Fix the collision

- [ ] 3.1 Convert `render_ffmpeg_test.exs` to a unique root
- [ ] 3.2 Move its test outputs off the fixture root: `Path.join(dir, "out.mp3")` and any sibling writes go to the per-test `:tmp_dir` instead. Check for others — `out.mp3` is the one found by reading, not necessarily the only one
- [ ] 3.3 Re-run 1.3's two-worktree reproduction and confirm it now passes repeatedly

## 4. Directive

- [ ] 4.1 Add the `Fixtures` row to `CLAUDE.md`'s *Test support* section, and with it the rule that a generated fixture path is never a fixed name under `System.tmp_dir!()` — worktree isolation covers the directory and the port, not the system temp dir
- [ ] 4.2 Since this closes the stack, read the whole *Test support* section once as a unit and make sure four changes' worth of rows still reads as one thing

## 5. Verify

- [ ] 5.1 `mix test --only ffmpeg` green — the only tag that exercises any of this
- [ ] 5.2 `mix test` and `mix test --include integration` green, confirming nothing leaked outside the tag
- [ ] 5.3 Compare `--only ffmpeg` runtime against 1.2. If losing the cross-run cache is material, add a within-run cache to the helper — not a shared path
- [ ] 5.4 `grep -rn "System.tmp_dir" test` returns hits only in the support module
- [ ] 5.5 After a full run, confirm the system temp dir holds no `audio_proxy_*` leftovers
- [ ] 5.6 `mix compile --warnings-as-errors` and `mix format --check-formatted`
