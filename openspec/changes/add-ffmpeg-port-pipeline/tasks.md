## 1. Port wrapper

- [x] 1.1 `AudioProxy.Ffmpeg.Render` GenServer + DynamicSupervisor: spawn_executable with argv, `:binary` + `:exit_status`, consumer monitor, exit trapping
- [x] 1.2 Chunk forwarding with outstanding-byte accounting (high-water pause, ack-based resume); `{:chunk, _} / {:done, _} / {:error, _}` consumer contract
- [ ] 1.3 Kill discipline: port close → SIGTERM → SIGKILL after grace, on consumer DOWN, cancel/1, and timeout; stderr → per-render temp file, tail read on failure
- [ ] 1.4 `AP_RENDER_TIMEOUT` timer; failure classification table (exit status + stderr patterns → :not_found | :undecodable | :timeout | :render_failed)

## 2. Tests with fake subprocess

- [x] 2.1 `test/support/fake_cmd.sh` (byte emitter / sleeper / nonzero-exit / TERM-ignoring variants)
- [x] 2.2 Byte fidelity + ordering; argv metacharacter pass-through
- [ ] 2.3 Orphan tests: consumer kill, cancel, timeout — assert OS pid gone within grace (incl. TERM-ignoring variant needing KILL)
- [ ] 2.4 Classification: exit-code/stderr fixtures map to each error class; stderr tail truncation

## 3. Integration (`@tag :ffmpeg`)

- [ ] 3.1 Fixture generation helper (`ffmpeg -f lavfi` sine/noise WAVs) in test setup
- [ ] 3.2 Real render: WAV→mp3 via command builder argv, output decodable (ffprobe), duration matches trim
- [ ] 3.3 Real failures: nonexistent path → :not_found class; text file input → :undecodable

## 4. Docs

- [ ] 4.1 Document render lifecycle guarantees, timeout config and the FIFO escalation note in `docs/rendering.md`, linked from the README documentation table, with the operator-facing `AP_RENDER_TIMEOUT` behaviour in the README's configuration section

  Retargeted from "update README": CLAUDE.md's documentation rule keeps
  implementation detail out of the README, and lifecycle, buffering and the
  FIFO escalation are all *how*, not *how to*. The consumer contract and
  buffering sections landed with tasks 1.1–1.2; the rest lands with 1.3–1.4.
