## 1. Baseline

- [ ] 1.1 Run `bin/smoke-image`, `bin/check-capacity`, `bin/check-capacity --self-test` and `bin/measure-ffmpeg-rss` against the current image and keep the output — this refactor's only real test is the before/after comparison

## 2. Extract

- [ ] 2.1 Support file under `bin/` (not executable, named so nobody tries to run it): `sh`, `sh!`, `docker_run`, `docker_rm`, `published_port`, `mib` and the byte constants, with the explanatory comments *moved* rather than copied
- [ ] 2.2 Extract the cgroup `anon` sampler once, interval as an explicit parameter; replace the probes in both `measure-ffmpeg-rss#measure` and `check-capacity#measure_ffmpeg_text`
- [ ] 2.3 Point the three scripts at it and delete their copies; leave `log`/`step`/`check`/`await_health`/`generate_fixtures`/`start_server` where they are

## 3. Verify

- [ ] 3.1 Re-run all four invocations from 1.1 and diff against the baseline; the capacity guard must still pass and its self-test must still fail the red path
- [ ] 3.2 Confirm CI is green, `smoke` and `capacity` in particular
