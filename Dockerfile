# syntax=docker/dockerfile:1

# Multi-stage build. Three stages, and the order matters: `runtime` is last, so
# a plain `docker build .` produces the shippable image and nothing else.
#
#   build   — hexpm/elixir on debian slim; compiles and assembles the release
#   test    — the same debian, plus ffmpeg and the test deps; the target CI uses
#             to run the :ffmpeg-tagged suite against the ffmpeg the image ships
#   runtime — debian slim; the release, ffmpeg, tini, and nothing else
#
# **Debian rather than Alpine, and that is a correctness decision.** On musl the
# BEAM aborts during startup with
#
#     sys_signal_stack.c:103:sys_sigaltstack(): Failed to set alternate signal stack
#
# and exits 134 (SIGABRT). It is intermittent and host-dependent: the size OTP
# requests for the JIT's alternate signal stack can fall below the kernel's
# MINSIGSTKSZ, which grows with CPU features, and OTP's workaround for it only
# ever worked against glibc. Measured at 2 failures in 10 runs on GitHub's
# runner fleet — in the *runtime* container, so it is the shipped image failing
# to boot rather than a flaky build. VERSIONS.md carries the full story.
#
# The versions below are pinned and recorded in VERSIONS.md. `build` and
# `runtime` MUST agree on the debian version: the ffmpeg the argv contract is
# tested against has to come from the same apt suite as the one that ships.
#
# ELIXIR_IMAGE is derived from DEBIAN_VERSION rather than written out, so the
# two cannot drift.

ARG DEBIAN_VERSION=trixie-20260713
ARG ELIXIR_VERSION=1.20.2
ARG OTP_VERSION=28.5.0.4
ARG ELIXIR_IMAGE=hexpm/elixir:${ELIXIR_VERSION}-erlang-${OTP_VERSION}-debian-${DEBIAN_VERSION}-slim

# ---------------------------------------------------------------------------
# build — compile and assemble the release
# ---------------------------------------------------------------------------
FROM ${ELIXIR_IMAGE} AS build

ENV MIX_ENV=prod \
    LANG=C.UTF-8 \
    DEBIAN_FRONTEND=noninteractive

# build-essential: the BEAM's own build tooling needs a C toolchain for any
# dependency shipping NIFs. git: for git-sourced deps. Neither reaches runtime.
RUN apt-get update \
    && apt-get install -y --no-install-recommends build-essential git \
    && rm -rf /var/lib/apt/lists/*

WORKDIR /src

RUN mix local.hex --force && mix local.rebar --force

# Dependencies before sources, so editing lib/ does not refetch or recompile
# the dependency tree.
COPY mix.exs mix.lock ./
RUN mix deps.get --only prod && mix deps.compile

# config/ is copied before lib/ because compile-time config invalidates
# everything downstream of it.
COPY config config
COPY lib lib
COPY rel rel

# Warnings are errors here for the same reason they are in CI: the compiler's
# set-theoretic type checker reports through warnings, so this is the type gate.
RUN mix compile --warnings-as-errors
RUN mix release --overwrite

# ---------------------------------------------------------------------------
# test — the :ffmpeg-tagged suite against the ffmpeg this image ships
# ---------------------------------------------------------------------------
# Not part of the runtime lineage; built explicitly with `--target test`. It
# installs ffmpeg from the same debian suite as the runtime stage, so the binary
# the argv contract is tested against is the package that is shipped.
FROM ${ELIXIR_IMAGE} AS test

ENV MIX_ENV=test \
    LANG=C.UTF-8 \
    DEBIAN_FRONTEND=noninteractive

RUN apt-get update \
    && apt-get install -y --no-install-recommends build-essential git ffmpeg \
    && rm -rf /var/lib/apt/lists/*

WORKDIR /src

RUN mix local.hex --force && mix local.rebar --force

COPY mix.exs mix.lock ./
RUN mix deps.get && mix deps.compile

COPY config config
COPY lib lib
COPY test test
COPY .formatter.exs README.md ./

CMD ["mix", "test", "--only", "ffmpeg"]

# ---------------------------------------------------------------------------
# runtime — what ships
# ---------------------------------------------------------------------------
FROM debian:${DEBIAN_VERSION}-slim AS runtime

ENV DEBIAN_FRONTEND=noninteractive

# ERTS is bundled by the release, but it links against the system glibc,
# libstdc++, ncurses and openssl — all already present in debian slim, so only
# what is genuinely missing is installed here. `ca-certificates` is for the
# HTTPS source fetches ffmpeg makes on its own; `wget` backs the HEALTHCHECK
# (debian slim ships neither wget nor curl); tini is PID 1 (see ENTRYPOINT).
RUN apt-get update \
    && apt-get install -y --no-install-recommends \
        ca-certificates \
        ffmpeg \
        tini \
        wget \
    && rm -rf /var/lib/apt/lists/*

# uid/gid 1000 matches the devcontainer, so a bind-mounted fixture directory
# has the same ownership story in both.
RUN groupadd --gid 1000 app \
    && useradd --uid 1000 --gid 1000 --home-dir /app --create-home --shell /usr/sbin/nologin app

WORKDIR /app

COPY --from=build --chown=app:app /src/_build/prod/rel/audio_proxy ./

USER app

# HOME is where the release writes its runtime scratch (RELEASE_TMP defaults
# under the release root, which app owns).
ENV HOME=/app \
    PORT=4000 \
    LANG=C.UTF-8

EXPOSE 4000

# AP_PORT wins over PORT, matching AudioProxy.Config's own precedence — a
# container told to listen elsewhere must be health-checked there too.
HEALTHCHECK --interval=10s --timeout=3s --start-period=15s --retries=3 \
    CMD wget -q -O /dev/null "http://127.0.0.1:${AP_PORT:-${PORT:-4000}}/health" || exit 1

# The release's beam handles SIGTERM itself; tini is there to reap the
# grandchildren a subprocess-heavy app can strand, and to make signal handling
# in PID 1 somebody else's solved problem.
ENTRYPOINT ["/usr/bin/tini", "--"]
CMD ["/app/bin/audio_proxy", "start"]

# Provenance. Passed by CI; `docker build` without them leaves the value empty
# rather than wrong. `image.source` is also what links the GHCR package to the
# repository.
ARG VERSION
ARG REVISION
LABEL org.opencontainers.image.title="audio_proxy" \
      org.opencontainers.image.description="On-the-fly audio transcoding proxy" \
      org.opencontainers.image.source="https://github.com/audioproxy/audioproxy" \
      org.opencontainers.image.url="https://github.com/audioproxy/audioproxy" \
      org.opencontainers.image.version="${VERSION}" \
      org.opencontainers.image.revision="${REVISION}"
