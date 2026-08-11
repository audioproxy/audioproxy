## Why

Five `:ffmpeg`-tagged files generate real audio fixtures, and all five hand-roll the same argv:

```elixir
System.cmd("ffmpeg", ["-nostdin", "-hide_banner", "-loglevel", "error", "-y",
                      "-f", "lavfi", "-i", <source>, "-ac", "2", …])
```

under four different wrapper names — `sine/2`, `generate/3`, `encode/3`, `sine_wav/1` — that differ only in which trailing options they append. Three of them also repeat the identical fixture-root setup: `Path.join(System.tmp_dir!(), "…-#{System.unique_integer([:positive])}")`, `File.mkdir_p!`, `on_exit(&File.rm_rf/1)`.

**Two of the five do not do that, and the difference is a bug.**

`test/audio_proxy/ffmpeg/render_ffmpeg_test.exs:31` uses a fixed path:

```elixir
dir = Path.join(System.tmp_dir!(), "audio_proxy_render_fixtures")
File.mkdir_p!(dir)
```

It is never removed, and tests write outputs *into* it — `Path.join(dir, "out.mp3")` at line 46. `test/audio_proxy/ffmpeg/command_ffmpeg_test.exs:26` does the same with a fixed filename, `audio_proxy_command_test_tone.wav`, and compounds it: the fixture is cached on `File.exists?` but `on_exit`s an `File.rm`, so a run deletes the fixture another run is caching on.

This project's entire workflow is parallel worktrees, each with its own devcontainer, deliberately isolated by directory and port. `System.tmp_dir!()` is shared by all of them. Two concurrent `mix test --only ffmpeg` runs collide on `out.mp3` and on the cached tone — one truncating a file the other is probing, presenting as an inexplicable codec or duration assertion failure in a test that has nothing wrong with it. The three files that use `unique_integer` are immune; nobody wrote down that this is why.

So the extraction and the fix are the same edit: one helper that owns the fixture root makes the unique-per-run root true by construction rather than by each file remembering.

## What Changes

- A new `AudioProxy.Fixtures` support module:
  - `root!/1` — a unique fixture root under the system tmp dir, `rm_rf` on exit. The isolation reason moves here.
  - `encode!/3` — the shared ffmpeg argv, taking the lavfi source and the trailing options each caller varies.
  - `sine/2`, `silence/2`, `video/1`, `tagged_mp3/2` — the named fixtures more than one file wants, expressed over `encode!/3`.
- The five files call it and lose their copies.
- **`render_ffmpeg_test.exs` and `command_ffmpeg_test.exs` move to unique roots**, closing the parallel-run collision. `render_ffmpeg_test.exs` also stops writing test outputs into the fixture root.
- The `CLAUDE.md` **Test support** section gains a row, with the directive that a fixture path is never a fixed name under `System.tmp_dir!()`.

**Deliberately not changed:**

- **Which fixtures each file generates.** `info_endpoint_ffmpeg_test.exs` wants one per container the contract has a rule about; `peaks_endpoint_ffmpeg_test.exs` wants a sine at a stated amplitude, digital silence, and a gapped signal. Those lists are each file's subject and stay in each file's `setup_all`. Only the *generation* is shared.
- **The stated-amplitude choice in the peaks fixtures.** `peaks_endpoint_ffmpeg_test.exs` uses `aevalsrc` with an explicit amplitude rather than bare `sine`, and its comment explains why: lavfi's `sine` is not full scale, so asserting against it would be asserting a version of ffmpeg. `Fixtures.sine/2` must preserve that — an amplitude argument, not a default.
- **The `unless File.exists?` caching.** Both fixed-path files cache to avoid regenerating a 20 s tone per run. With a unique root the cache no longer spans runs, which is the correct behaviour and costs one encode per suite run; measure it rather than assuming, and keep a within-run cache if `setup_all` alone does not cover it.

## Capabilities

### New Capabilities

<!-- none — `test-support` is introduced by `extract-test-polling` -->

### Modified Capabilities

- `test-support` — gains requirements for fixture generation and fixture-path isolation.

## Impact

- New: `test/support/fixtures.ex`.
- Modified: `test/audio_proxy/ffmpeg/render_ffmpeg_test.exs`, `ffmpeg/command_ffmpeg_test.exs`, `info_endpoint_ffmpeg_test.exs`, `render_endpoint_ffmpeg_test.exs`, `peaks_endpoint_ffmpeg_test.exs`.
- Modified: `CLAUDE.md` — a row in *Test support*, and the fixed-path rule.
- **Fixes a real collision**, not only duplication: two concurrent `--only ffmpeg` runs across worktrees currently share fixture paths.
- Last of four stacked changes. Depends on the three before it; rebase onto them.
- Only `:ffmpeg`-tagged files, so verification requires `mix test --only ffmpeg` — a default `mix test` exercises none of this.
- No `lib/`, CI, config or user-facing docs changes.
