## 1. Baseline

- [x] 1.1 Record the current suite runtime, split three ways, as the comparison this refactor is verified against: `mix test`, `mix test --include integration`, and the property files alone (`mix test test/audio_proxy/*_property_test.exs`). The last matters most — the 5 ms polls being unified live inside a property loop

  | Suite | Before | After |
  |---|---|---|
  | `mix test` | 38.8 s, 963 passed | 38.5 s, 963 passed |
  | `mix test --include integration` | 44.2 s, 984 passed | 44.0 s, 984 passed |
  | `test/audio_proxy/*_property_test.exs` | 6.9 s, 24 passed | 6.8 s, 24 passed |

- [x] 1.2 List the 13 files and their current deadlines before touching anything, so a deadline silently changed during extraction is visible in review rather than in a flake three weeks later

  The census was short. **Seventeen** files held a copy, not thirteen: `wait_until` was in eleven files rather than nine, and a fourth name — `await/2`, in `readiness_test.exs` and `ready_endpoint_test.exs` — was missed entirely. Both extra pairs are folded in here; the spec's rule ("any test that waits by polling uses the shared module") does not leave room to skip them.

  | File | Helper | Deadline | Interval | Now |
  |---|---|---|---|---|
  | `probe_coordinator_test.exs` | `wait_until` | 5 s (literal, not its `@deadline`) | 25 ms | explicit `5_000`, so the file's 10 s `@deadline` cannot be misread as the budget |
  | `probe_endpoint_test.exs` | `wait_until` | `@deadline` 10 s | 10 ms | explicit `@deadline` |
  | `probe_limiter_property_test.exs` | `wait_until` | `@deadline` 10 s | 10 ms | explicit `@deadline` |
  | `probe_limiter_test.exs` | `wait_until` | `@deadline` 5 s | 25 ms | default |
  | `render_coordinator_test.exs` | `wait_until`, `gone_within?`, `alive?` | `@deadline` 5 s | 10/25 ms | default |
  | `render_endpoint_test.exs` | `wait_until` | `@deadline` 5 s | 10 ms | default; its now-unused `@deadline` deleted |
  | `render_semaphore_test.exs` | `wait_until` | `@deadline` 10 s | 20 ms | explicit `@deadline` |
  | `semaphore_property_test.exs` | `wait_until` | `@deadline` 10 s | 5 ms | explicit `@deadline` |
  | `semaphore_test.exs` | `wait_until` | `@deadline` 2 s | 10 ms | explicit `@deadline` |
  | `variant_cache_test.exs` | `wait_until` | `@deadline` 5 s | 10 ms | default; its now-unused `@deadline` deleted |
  | `variant_store/tee_test.exs` | `wait_until` | `@deadline` 5 s | 10 ms | default |
  | `render_endpoint_stream_test.exs` | `gone_within?` (inlined `kill`) | passed per call | 25 ms | unchanged |
  | `ffmpeg/render_ffmpeg_test.exs` | `gone_within?`, `alive?` | passed per call | 25 ms | unchanged |
  | `ffmpeg/render_lifecycle_test.exs` | `eventually`, `gone_within?`, `alive?` | 2 s / per call | 25 ms | explicit `2_000` |
  | `peaks_endpoint_ffmpeg_test.exs` | `eventually` | 40 attempts, a render each | 50 ms | explicit `10_000` — see 2.4 |
  | `readiness_test.exs` | `await` | `@deadline` 2 s | 10 ms | explicit `@deadline` |
  | `ready_endpoint_test.exs` | `await` | `@deadline` 2 s | 10 ms | explicit `@deadline` |

  Every `wait_until` call site used the local default, so a file whose budget is not the module's 5 s default now passes `@deadline` at the call site — which is what "deadlines stay at the call site" asks for, and what keeps each budget exactly where it was.

## 2. Extract

- [x] 2.1 `test/support/eventually.ex` with `wait_until/2` (flunks, message names the exceeded deadline), `eventually?/2` (boolean), `gone_within?/2` and `alive?/1` — the last two written in terms of `eventually?/2`, not as their own loop
- [x] 2.2 Moduledoc explaining the flunk/boolean split and why the deadline stays a parameter while the interval does not. This is the file's real content; the four functions are trivial
- [x] 2.3 Replace the copies in the nine `wait_until` files, preserving each file's `@deadline` exactly — eleven files, per 1.2
- [x] 2.4 Replace the two `eventually` files — `peaks_endpoint_ffmpeg_test.exs` counts attempts rather than milliseconds (`attempts \\ 40` at 50 ms), so convert to a millisecond deadline and check the arithmetic: 40 × 50 ms is 2 s, not the 60 s its `@deadline` suggests. Converted to an explicit deadline; the file's `@deadline` belongs to `RawHttp.read/2` and is untouched. **The 2 s that arithmetic implies is wrong**, as the adversarial review caught: the condition is a full render through ffmpeg and ffprobe, and the old scheme charged the budget for sleeps only, so 40 attempts meant 40 renders however long each took. Under a wall-clock deadline 2 s buys roughly six attempts on a loaded runner. It is `10_000`, with a comment saying the budget is renders rather than polls
- [x] 2.5 Replace `gone_within?`/`alive?` in the four files that have them, including `render_endpoint_stream_test.exs`, whose copy inlines `System.cmd("kill", …)` rather than calling a local `alive?`
- [x] 2.6 Confirm `mix compile --warnings-as-errors` is clean — an unused private function is the compiler telling you a deletion was missed. Clean; `mix test` additionally surfaced two now-unused `@deadline` attributes (both 5 s, the module default), deleted rather than kept

## 3. Directive

- [x] 3.1 Add a **Test support** section to `CLAUDE.md`: what lives in `test/support/`, and the rule that a poll loop is imported rather than written. Place it near *Conventions*, where the typing and cache-key rules already are — the section already existed for `SignedRequest`, so this extends it
- [x] 3.2 Word it so the next three changes in this stack extend it by adding a row rather than by rewriting the section — an index table of the shared modules leads the section, with a per-module subsection under it

## 4. Verify

- [x] 4.1 `mix test`, `mix test --include integration`, `mix test --only ffmpeg` all green. The first two are green. `--only ffmpeg` is 45/47: both failures are `f:ogg/q:5` in `command_ffmpeg_test.exs`, a file this change does not touch, on a local ffmpeg built without `libvorbis` — the same environmental failure recorded on `main` for the previous change, which CI does not reproduce
- [x] 4.2 Compare the property-suite runtime against 1.1. A visible regression means `semaphore_property_test.exs` passes its own 5 ms interval — the module's default does not move. 6.8 s against 6.9 s: no regression, so the 10 ms default stands
- [x] 4.3 Confirm no file still defines a private `wait_until`, `eventually`, `gone_within?` or `alive?`: `grep -rn "defp wait_until\|defp eventually\|defp gone_within?\|defp alive?" test`
- [x] 4.4 `mix format --check-formatted`

## Deferred out of this change

`metrics_endpoint_test.exs`'s `await_scrape/3` and `metrics_test.exs`'s `await_restart/2` are poll loops and stay where they are. Both **return the value they waited for** — a scrape body, a restarted pid — which `wait_until/2` and `eventually?/2` cannot express, and both carry a bespoke failure message. Folding them in means either widening the module's contract or rewriting the two tests to poll-then-re-read, neither of which is a deduplication — and the second reopens the race the poll exists to close. Deferred to **`extract-test-value-waits`**, which is on the board and states the shape decision it has to make.
