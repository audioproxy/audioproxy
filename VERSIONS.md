# Pinned versions

What the release image is built from. `.tool-versions` pins Elixir and
Erlang/OTP for the *repository* — mise reads it locally, `erlef/setup-beam`
reads it in CI. This file pins the *image*, and the two have to say the same
thing about Elixir and OTP: the release the container runs is compiled by the
toolchain named here.

| What | Version | Where it is written |
|---|---|---|
| Erlang/OTP | `28.5.0.4` | `.tool-versions`, `Dockerfile` (`OTP_VERSION`), `.devcontainer/Dockerfile` |
| Elixir | `1.20.2` (OTP 28) | `.tool-versions`, `Dockerfile` (`ELIXIR_VERSION`), `.devcontainer/Dockerfile` |
| Debian | `trixie-20260713` | `Dockerfile` (`DEBIAN_VERSION`; `ELIXIR_IMAGE` is derived from it) |
| ffmpeg / ffprobe | `7.1.5` | Debian trixie's `ffmpeg` package; the major is asserted in CI |

`ELIXIR_IMAGE` is derived from `DEBIAN_VERSION` in the Dockerfile rather than
written out, because the build and runtime stages must name the same Debian
version: the ffmpeg the argv contract is tested against has to be the package
the runtime stage installs.

## Why Debian and not Alpine

The image was Alpine first, per the original stack decision, and had to move.
**On musl the BEAM intermittently aborts during startup:**

    sys_signal_stack.c:103:sys_sigaltstack(): Internal error: Failed to set alternate signal stack

with exit code 134 (SIGABRT). It is host-dependent, not load-dependent: the size
OTP requests for the JIT's alternate signal stack can fall below the kernel's
`MINSIGSTKSZ`, which grows with CPU features, and [OTP's workaround for this only
ever worked against glibc](https://github.com/erlang/otp/pull/7174).

This was measured at **2 failures in 10 runs** on GitHub's runner fleet, in the
*runtime* container — the shipped image failing to boot, not a flaky build. On a
mixed fleet roughly one container start in five would have died, and the failure
never reproduces on a developer machine, which is what makes it worth this much
prose. It was caught by the container smoke suite before `v0.1.0` was tagged.

Two consequences worth keeping in mind:

- **Do not "optimise" the image back to Alpine for size.** It costs about 80 MB
  over the Alpine equivalent. That is the price of a release that boots.
- The devcontainer was Debian all along, so dev and prod now agree on ffmpeg
  instead of differing by a major. The gap this file used to document is closed.

## What CI asserts

The ffmpeg major is recorded once, on the line below, and both
[`bin/smoke-image`](bin/smoke-image) and the `image-ffmpeg` CI job parse *that
line*. It is written as a key/value rather than as prose so there is exactly one
place to change and no second copy to fall out of step:

    FFMPEG_MAJOR=7

- The runtime image's `ffmpeg -version` must report that major. A bump that
  moves it fails the pipeline until this file moves with it.
- The `test` and `runtime` stages must report the *same* ffmpeg build, so the
  encoder the argv contract is checked against is the one that ships.

## Bumping a pin

A pin bump changes what the image renders — a different encoder emits different
bytes for the same URL — so it is a release, not a silent update. The procedure:

1. Edit `Dockerfile` (`DEBIAN_VERSION`, `ELIXIR_VERSION`, `OTP_VERSION`),
   `.tool-versions` and `.devcontainer/Dockerfile` together; Elixir and OTP move
   as a pair.
2. Rebuild and read the new ffmpeg version out of the image:
   `docker build -t audio_proxy:pin-check . && docker run --rm --entrypoint ffmpeg audio_proxy:pin-check -version`
3. Update the table above, and `FFMPEG_MAJOR` if the major moved. If it did,
   expect the argv contract to need real work — run the full `:ffmpeg` suite and
   read the failures rather than adjusting the assertion.
4. Regenerate the measured memory table:
   `bin/measure-ffmpeg-rss --write docs/capacity.md`. A different ffmpeg holds
   different memory, and [docs/capacity.md](docs/capacity.md) is what an
   operator sizes a container from — a stale table is a wrong memory limit.
   Commit the regenerated table with the bump; a bump that moves the numbers
   noticeably belongs in the release notes.
5. Regenerate the decision matrix on top of it:
   `bin/capacity-matrix --write docs/capacity.md`. It reads the table step 4 just
   rewrote, so it has to run second, and it is what an operator actually reads —
   a correct table under a stale matrix is a wrong memory limit with an audit
   trail. Needs no docker; commit both in the same change.
6. Run `bin/smoke-image` locally, then let CI run it again.
7. Cut a patch release (see [docs/development.md](docs/development.md#releases)).
