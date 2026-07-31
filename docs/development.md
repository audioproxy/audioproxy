# Development

How work happens in this repository: the pinned toolchain, the per-slice
worktree workflow, the test suite and its tags, and the CI gate. None of it is
needed to run the proxy — see the [README](../README.md) for that.

## Toolchain

Elixir and Erlang/OTP are pinned as a matched pair in
[`.tool-versions`](../.tool-versions); bump them together. That file is the single
source of truth — mise reads it locally and `erlef/setup-beam` reads it in CI,
so CI cannot drift from your shell.

```bash
mise install
```

Elixir 1.20 is a floor, not a preference: the type gate here is the compiler's
own set-theoretic checker, surfaced by `mix compile --warnings-as-errors` in CI.
There is no Dialyzer and no `dialyxir` — nothing to keep a PLT warm for, and no
second type system whose opinions have to be reconciled with the compiler's.

`@type t` and `@spec` go on public seams only, where they are worth reading in
ExDoc and useful to the LSP. Private plumbing goes unannotated; the checker
infers it.

## Running the suite

```bash
mix deps.get
mix test
mix format --check-formatted
```

Both are part of the CI gate — a change is not done until both pass. The suite
drives the router through `Plug.Test` and binds no socket, so several copies can
run concurrently.

Tests tagged `:ffmpeg` shell out to the real binaries and are excluded by
default — they render every format and every filter through the actual
encoder, which is the only way an assumption about a codec name gets checked.
Run them explicitly, on a machine that has ffmpeg installed (the devcontainer
does):

```bash
mix test --only ffmpeg
```

Tests tagged `:integration` bind a real socket (Bandit on a fixed port) to
verify adapter behavior end-to-end — currently that the signed request path
reaches the verifier byte-identical to what the client sent. They are
excluded by default but run in CI; locally:

```bash
mix test --include integration
```

Property tests use [StreamData](https://github.com/whatyouhide/stream_data),
which is a test-only dependency. Every processing option must round-trip
(parse → normalize → cache key → identical ffmpeg args), so option handling is
property-tested rather than only example-tested.

The generators live in `AudioProxy.OptionsGenerators` and are shared by the
options and ffmpeg-argv suites — both rest on the same round-trip, so they
must probe the same grammar. They are built format-first, so every cross-key
rule holds by construction: a property that has to filter its own inputs has
stopped testing what it claims to test.

Tests that need config other than the defaults use
`AudioProxy.ConfigHelper.put_config/1`, which swaps `:persistent_term` and
restores it on exit; such tests must set `async: false`. Prefer
`AudioProxy.Config.build!/1` — pure and async-safe — when you only need to check
parsing or validation.

## Continuous integration

[`.github/workflows/ci.yml`](../.github/workflows/ci.yml) runs on every push to
`main` and every pull request, in two jobs:

| Job | Runs | Notes |
|---|---|---|
| `test` | `mix format --check-formatted`, `mix compile --warnings-as-errors`, `mix test --include integration` | No external binaries — the untagged + `:integration` suite must pass on a bare runner |
| `test-ffmpeg` | `mix test --only ffmpeg` | Installs ffmpeg first; renders every format and filter through the real binary |

Compilation runs with warnings as errors because the compiler's set-theoretic
type checker reports through warnings — that flag is what makes the type gate a
gate rather than a suggestion.

Both jobs read Elixir and Erlang/OTP from [`.tool-versions`](../.tool-versions),
so bumping the pin is a one-file change that CI follows automatically. The
`deps`/`_build` cache is keyed on the resolved versions plus `mix.lock`, so a
toolchain bump misses the cache rather than restoring BEAM files built by a
different compiler.

Later slices extend this workflow rather than adding parallel ones — the image
build and smoke tests from `add-docker-release`, and MinIO as a service
container from `add-s3-client` — so there stays exactly one check to require.

[`.github/dependabot.yml`](../.github/dependabot.yml) opens update PRs weekly for
Hex packages and GitHub Actions. Minor and patch updates are grouped into one PR
per ecosystem; majors come individually. Every one of them is gated by the
workflow above.

`main` is protected: pull requests cannot merge until both jobs pass, and the
branch rejects force-pushes and deletion. **Branch protection is a repo setting,
not a file**, so it does not travel with a clone — a fork has to set it up
again, under *Settings → Branches → Add rule* for `main`, requiring the checks
named **format, compile, unit tests** and **ffmpeg-tagged tests** (GitHub lists
status checks by job name, not by the job's key in the YAML).

---

## Per-slice worktrees

Every feature slice gets its own git worktree paired with its own devcontainer,
managed with [worktrunk](https://worktrunk.dev) (`wt`). The app is stateless, so
isolation is just directory plus port — no per-branch database exists.

```bash
brew install worktrunk

# Create the worktree and its devcontainer (deps + compile run inside)
wt switch --create add-options-parser

# Boot the app on this branch's port
wt start add-options-parser

# Run commands inside this worktree's container
bin/agent-exec mix test
bin/agent-exec mix format --check-formatted

# Merge back and tear down
wt merge add-options-parser
wt remove add-options-parser
```

Each branch gets a deterministic port in 10000–19999 from worktrunk's
`hash_port` filter, so several worktrees can run at once without colliding.
`wt list` shows each worktree's URL. The port is passed to the container at
create time (so it can be published) and at boot time (so Bandit binds it) by
the hooks in [`.config/wt.toml`](../.config/wt.toml).

The devcontainer image
([`.devcontainer/Dockerfile`](../.devcontainer/Dockerfile)) pins the same
Elixir/OTP pair as `.tool-versions`, plus `ffmpeg`/`ffprobe` — they are part of
the product, so the `:ffmpeg`-tagged tests need the real binaries.

The binstubs are host/container dual-purpose — they branch on the `DEVCONTAINER`
env var so they never recurse through `devcontainer exec`:

| Binstub | On the host | In the container |
|---|---|---|
| `bin/agent-setup` | `devcontainer up` | `mix deps.get` + compile (dev & test) |
| `bin/agent-server` | delegates via `bin/agent-exec` | `mix run --no-halt` |
| `bin/agent-exec` | `devcontainer exec` | refuses — run the command directly |
| `bin/agent-cleanup` | removes the worktree's container | refuses |

Use `devcontainer up` / `devcontainer exec` (i.e. the binstubs) rather than raw
`docker compose`: only the devcontainer CLI applies `containerEnv` and the
`postCreateCommand`.

One OpenSpec change per worktree; merge back when its tasks are checked off and
the suite is green.
