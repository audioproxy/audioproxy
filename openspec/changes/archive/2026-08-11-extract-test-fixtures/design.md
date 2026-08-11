## Context

Last of four stacked changes. Unlike the other three, this one is not purely a tidy-up: two of the five files it touches use fixed paths under `System.tmp_dir!()`, which collide between parallel worktree runs. The extraction is the fix.

## Goals / Non-Goals

**Goals:**
- One implementation of the ffmpeg fixture argv.
- Fixture roots unique per run by construction, with the reason written down once.
- No change to what any fixture *is* — same codecs, same rates, same amplitudes.

**Non-Goals:**
- A shared fixture catalogue. Which fixtures a file wants is that file's subject.
- Committing fixtures to the repo. They are generated so they are what *this* ffmpeg produces, which is the point of the `:ffmpeg` tag; a committed mp4 would pin a mapping against a binary nobody in the loop is running.
- Touching the shell stand-ins (`fake_ffmpeg.sh`, `fake_ffprobe.sh`, `counting_ffprobe.sh`). Those are directive-driven fakes, a different mechanism entirely.

## Decisions

- **The fixture root is unique per run, always.** No option to opt out. The two fixed-path files exist because the option was implicitly available; removing it is the fix. `System.unique_integer([:positive])` plus `on_exit(&File.rm_rf/1)` matches what the three correct files already do.
- **Outputs do not go in the fixture root.** `render_ffmpeg_test.exs` writes `out.mp3` next to its inputs, which is the sharper half of the collision: two runs probing each other's output. Test outputs go to the per-test `:tmp_dir` that ExUnit already provides, which is unique per test rather than per module.
- **`encode!/3` takes the lavfi source string, not a fixture name.** The five callers vary in the source (`sine=…`, `aevalsrc=…`, `anullsrc=…`) and in the trailing codec options, and both have to stay at the call site or the helper becomes a switch statement over five files' needs. The named helpers (`sine/2`, `silence/2`) sit on top for the cases more than one file wants, and a file with a one-off calls `encode!/3` directly.
- **`sine/2` takes amplitude explicitly.** Preserving `peaks_endpoint_ffmpeg_test.exs`'s reasoning: lavfi's bare `sine` is not full scale, and a fixture whose amplitude is inherited from an ffmpeg default makes the peaks assertions assert a version of ffmpeg instead of a contract. Amplitude is an argument; the comment moves with it.
- **There are two sine generators, not one** — decided while implementing. This design assumed `sine/2` could serve all four of its callers. It cannot without changing three fixtures: measured with `volumedetect`, `lavfi`'s bare `sine` peaks at **-21.1 dB** against **0.0 dB** for a unit `aevalsrc`, so folding the three files that use `sine=` onto an amplitude-bearing generator would make their sources 21 dB louder, which "no change to what any fixture *is*" forbids. So `tone/2` is the bare `lavfi` sine, for tests about transcoding; `sine/2` is the amplitude-bearing one, for tests about signal. The measurement is in the moduledoc so the next reader need not take either on trust.
- **Caching is re-measured, not preserved by default.** Both fixed-path files cache on `File.exists?` across runs, which a unique root ends. That was buying at most one 20 s tone encode per run — plausibly nothing, given `setup_all` already generates once per module. Measure `--only ffmpeg` before and after; if it is material, the answer is a within-run cache in the helper, not a shared path.
- **`root!/1` takes a label.** `Fixtures.root!("peaks")` produces `…/audio_proxy_peaks_fixtures-<n>`, so a leftover directory on a crashed run says which suite left it. The three correct files already do this by hand.

## Risks / Trade-offs

- [Losing the cross-run fixture cache slows `--only ffmpeg`] → measured in the tasks rather than assumed. The mitigation if it is real is a within-run cache; a shared path is not on the table, since it is the defect being fixed.
- [Only `:ffmpeg`-tagged tests exercise this] → so a green `mix test` proves nothing here. Verification is `mix test --only ffmpeg`, and specifically two of them at once from two worktrees, which is the case that is broken today and the only way to show it is fixed.
- [A helper could obscure what a fixture contains] → the named helpers state their parameters (duration, amplitude, rate) at the call site, and the per-file `setup_all` still reads as a list of what that file needs. The argv boilerplate is the only thing that disappears, and no reader was getting anything from it.
