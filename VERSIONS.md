# Pinned versions

What the release image is built from. `.tool-versions` pins Elixir and
Erlang/OTP for the *repository* — mise reads it locally, `erlef/setup-beam`
reads it in CI. This file pins the *image*, and the two have to say the same
thing about Elixir and OTP: the release the container runs is compiled by the
toolchain named here.

| What | Version | Where it is written |
|---|---|---|
| Erlang/OTP | `28.5.0.4` | `.tool-versions`, `Dockerfile` (`ELIXIR_IMAGE`), `.devcontainer/Dockerfile` |
| Elixir | `1.20.2` (OTP 28) | `.tool-versions`, `Dockerfile` (`ELIXIR_IMAGE`), `.devcontainer/Dockerfile` |
| Alpine | `3.24.1` | `Dockerfile` (`ALPINE_VERSION`, and the alpine suffix of `ELIXIR_IMAGE`) |
| ffmpeg / ffprobe | `8.1.2` — **major 8** | Alpine 3.24's `ffmpeg` package; asserted in CI |

The build and runtime stages must name the same Alpine version. The release
links against musl from the build stage, and the ffmpeg the argv contract is
tested against has to be the package the runtime stage installs — an Alpine
mismatch silently breaks both.

## What CI asserts

- `ffmpeg -version` in the runtime image reports major **8**. A bump that moves
  the major fails the pipeline until this file and the expectation move with it.
- The `:ffmpeg`-tagged suite runs inside the `test` stage, which installs ffmpeg
  from the same Alpine version as the runtime stage — so the encoder the argv
  contract is checked against is the one that ships.

## Bumping a pin

A pin bump changes what the image renders — a different encoder emits different
bytes for the same URL — so it is a release, not a silent update. The procedure:

1. Edit `Dockerfile` (`ALPINE_VERSION` and/or `ELIXIR_IMAGE`), `.tool-versions`
   and `.devcontainer/Dockerfile` together; Elixir and OTP move as a pair.
2. Rebuild and read the new ffmpeg version out of the image:
   `docker build -t audio_proxy:pin-check . && docker run --rm --entrypoint ffmpeg audio_proxy:pin-check -version | head -1`
3. Update the table above. If the ffmpeg major moved, expect the argv contract
   to need real work — run the full `:ffmpeg` suite and read the failures rather
   than adjusting the assertion.
4. Run `bin/smoke-image` locally, then let CI run it again.
5. Cut a patch release (see [docs/development.md](docs/development.md#releases)).

### Known gap

The devcontainer is Debian trixie and its ffmpeg is 7.x, while the release image
is Alpine and 8.x. `mix test --only ffmpeg` therefore checks a *different*
ffmpeg locally than the one that ships. CI closes the gap by running the same
suite in the `test` stage; a local green is a strong hint, not the gate.
