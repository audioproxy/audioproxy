## 1. Baseline

- [x] 1.1 Branch from `main` at or after `extract-signed-request-helper` merges — it is the last of the three this one rebases onto
- [x] 1.2 Time `mix test --only ffmpeg` and keep the number. The cross-run fixture cache disappears in this change, and 4.3 decides whether that mattered — **72.8 s on the host; 34.4 s in the devcontainer** (cold, fixed paths removed first)
- [x] 1.3 **Reproduce the collision before fixing it.** Run `mix test --only ffmpeg` from two worktrees simultaneously and capture the failure. It presents as a codec or duration assertion failing in a test with nothing wrong with it; if it does not reproduce on the first try, run it a few times — it is a race. A fix for a bug nobody has seen fail is a fix nobody can verify — **reproduced on the first round.** Two host checkouts, `--only ffmpeg`: `t:0:10/fade:0.5:1 exited 254: "Error opening input file …/audio_proxy_command_test_tone.wav. No such file or directory"` — one run's `on_exit(File.rm)` deleting the tone the other was rendering against
- [x] 1.4 Clean up any leftovers from the current fixed paths before starting: `rm -rf $TMPDIR/audio_proxy_render_fixtures $TMPDIR/audio_proxy_command_test_tone.wav`

## 2. Extract

- [x] 2.1 `test/support/fixtures.ex` with `root!/1` (labelled, unique, `rm_rf` on exit), `encode!/3` (lavfi source plus trailing options), and the named helpers `sine/2`, `silence/2`, `video/1`, `tagged_mp3/2`
- [x] 2.2 `sine/2` takes amplitude explicitly, and the comment explaining why — lavfi's bare `sine` is not full scale, so an inherited amplitude makes the peaks assertions assert a version of ffmpeg — **moves** from `peaks_endpoint_ffmpeg_test.exs` onto it
- [x] 2.3 Moduledoc records the isolation rule and what it is defending against: parallel worktree runs sharing `System.tmp_dir!()`, and what the failure looked like when it was found (1.3's capture)
- [x] 2.4 Convert the three files already using unique roots — `info_endpoint_ffmpeg_test.exs`, `render_endpoint_ffmpeg_test.exs`, `peaks_endpoint_ffmpeg_test.exs` — keeping each file's fixture *list* and its comments in place
- [x] 2.5 Convert `command_ffmpeg_test.exs` to a unique root, dropping the `unless File.exists?` cache and the `on_exit(File.rm)` that fought it

## 3. Fix the collision

- [x] 3.1 Convert `render_ffmpeg_test.exs` to a unique root
- [x] 3.2 Move its test outputs off the fixture root: `Path.join(dir, "out.mp3")` and any sibling writes go to the per-test `:tmp_dir` instead. Check for others — `out.mp3` is the one found by reading, not necessarily the only one
- [x] 3.3 Re-run 1.3's two-worktree reproduction and confirm it now passes repeatedly — four concurrent rounds, no fixture collision in any of them. Two rounds failed a *different* assertion (`class: :render_failed, stderr: ""`), which the same reproduction run against **unconverted** code produces in 5 of 12 runs: `Render.scratch_dir/0` is namespaced per *node*, every `mix test` is `nonode@nohost`, so two runs sweep each other's live stderr files at boot — the symptom `lib/audio_proxy/ffmpeg/render.ex:549` predicts in its own comment. Same defect class, in `lib/`, out of this change's scope

## 4. Directive

- [x] 4.1 Add the `Fixtures` row to `CLAUDE.md`'s *Test support* section, and with it the rule that a generated fixture path is never a fixed name under `System.tmp_dir!()` — worktree isolation covers the directory and the port, not the system temp dir
- [x] 4.2 Since this closes the stack, read the whole *Test support* section once as a unit and make sure four changes' worth of rows still reads as one thing

## 5. Verify

- [x] 5.1 `mix test --only ffmpeg` green — 47/47 in the devcontainer. On the host two `f:ogg` assertions fail before and after, unrelated: ffmpeg 8.1.1 there has no `libvorbis`
- [x] 5.2 `mix test` (963) and `mix test --include integration` (984) green; the whole suite with both tags included is 1031
- [x] 5.3 Compare `--only ffmpeg` runtime against 1.2 — **34.4 s before, 26.2 s after**, same container, both cold. Losing the cross-run cache costs nothing measurable, so no within-run cache was added
- [x] 5.4 `grep -rn "System.tmp_dir" test` returns hits only in the support module. Two beyond the five files were folded in to get there: `render_endpoint_ffmpeg_test.exs`'s probe output (now the test's `:tmp_dir`) and `render_semaphore_test.exs`'s `store_root/0`, which was `root!/1` hand-rolled
- [x] 5.5 After a full run, confirm the system temp dir holds no `audio_proxy_*` leftovers — none from the suite. `audio_proxy_render-nonode@nohost` remains: it is `Render.scratch_dir/0`'s, from `lib/`, and is the 3.3 note's subject
- [x] 5.6 `mix compile --warnings-as-errors` and `mix format --check-formatted`
