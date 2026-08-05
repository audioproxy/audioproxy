## 1. Baseline

- [x] 1.0 Branch from `main` at or after #41 (merged 2026-08-05): it rewrote `check-capacity`'s constants and added `bin/capacity_model.rb` beside where this file goes, so extracting against the pre-#41 script would re-create copies it just removed. Satisfied by any worktree cut from `main` now — kept as a task because the *reason* is what the next reader needs
- [x] 1.1 Run `bin/smoke-image`, `bin/check-capacity`, `bin/check-capacity --self-test` and `bin/measure-ffmpeg-rss` against the current image and keep the output — this refactor's only real test is the before/after comparison

## 2. Extract

- [x] 2.1 Support file under `bin/` (not executable, named so nobody tries to run it): `sh`, `sh!`, `docker_run`, `docker_rm`, `published_port` and the docker/shell byte constants, with the explanatory comments *moved* rather than copied
- [x] 2.1a Leave `mib`/`MIB` where #41 put them, in `bin/capacity_model.rb` — a second definition in the plumbing file is the duplication this change exists to remove. `smoke-image` gets them by requiring that file, or keeps its own if it turns out not to want the model; decide by which reads better at the call site, not by tidiness
- [x] 2.2 Extract the cgroup `anon` sampler once, interval as an explicit parameter; replace the probes in both `measure-ffmpeg-rss#measure` and `check-capacity#measure_ffmpeg_text`
- [x] 2.3 Point the three scripts at it and delete their copies; leave `log`/`step`/`check`/`await_health`/`generate_fixtures`/`start_server` where they are

## 3. Verify

- [x] 3.1 Re-run all four invocations from 1.1 and diff against the baseline; the capacity guard must still pass and its self-test must still fail the red path
- [ ] 3.2 Confirm CI is green, `smoke` and `capacity` in particular
