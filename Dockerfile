# syntax=docker/dockerfile:1

# Multi-stage build. Three stages, and the order matters: `runtime` is last, so
# a plain `docker build .` produces the shippable image and nothing else.
#
#   build   — hexpm/elixir on alpine; compiles and assembles the mix release
#   test    — the same alpine, plus ffmpeg and the test deps; the target CI uses
#             to run the :ffmpeg-tagged suite against the ffmpeg the image ships
#   runtime — bare alpine; the release, ffmpeg, tini, and nothing else
#
# The versions below are pinned and recorded in VERSIONS.md. `build` and
# `runtime` MUST agree on the alpine version: the release links against musl
# from the build stage, and the ffmpeg the argv contract is tested against comes
# from the same alpine package repository as the one that is shipped.

ARG ALPINE_VERSION=3.24.1
ARG ELIXIR_IMAGE=hexpm/elixir:1.20.2-erlang-28.5.0.4-alpine-3.24.1

# ---------------------------------------------------------------------------
# build — compile and assemble the release
# ---------------------------------------------------------------------------
FROM ${ELIXIR_IMAGE} AS build

ENV MIX_ENV=prod \
    LANG=C.UTF-8

# build-base: the BEAM's own build tooling needs a C toolchain for any
# dependency shipping NIFs. git: for git-sourced deps. Neither reaches runtime.
RUN apk add --no-cache build-base git

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
# installs ffmpeg from the same alpine version as the runtime stage, so the
# binary the argv contract is tested against is the package that is shipped.
FROM ${ELIXIR_IMAGE} AS test

ENV MIX_ENV=test \
    LANG=C.UTF-8

RUN apk add --no-cache build-base git ffmpeg

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
FROM alpine:${ALPINE_VERSION} AS runtime

# ERTS is bundled by the release, but it links against the system musl,
# libstdc++, ncurses and openssl; `ca-certificates` is for the HTTPS source
# fetches ffmpeg makes on its own. tini is PID 1 (see ENTRYPOINT).
RUN apk add --no-cache \
        ca-certificates \
        ffmpeg \
        libgcc \
        libstdc++ \
        ncurses-libs \
        openssl \
        tini

# uid/gid 1000 matches the devcontainer, so a bind-mounted fixture directory
# has the same ownership story in both.
RUN addgroup -g 1000 -S app \
    && adduser -u 1000 -S -G app -h /app app

WORKDIR /app

COPY --from=build --chown=app:app /src/_build/prod/rel/audio_proxy ./

USER app

# HOME is where the release writes its runtime scratch (RELEASE_TMP defaults
# under the release root, which app owns).
ENV HOME=/app \
    PORT=4000 \
    LANG=C.UTF-8

EXPOSE 4000

# busybox wget, so the image needs no curl. AP_PORT wins over PORT, matching
# AudioProxy.Config's own precedence — a container told to listen elsewhere must
# be health-checked there too.
HEALTHCHECK --interval=10s --timeout=3s --start-period=15s --retries=3 \
    CMD wget -q -O /dev/null "http://127.0.0.1:${AP_PORT:-${PORT:-4000}}/health" || exit 1

# The release's beam handles SIGTERM itself; tini is there to reap the
# grandchildren a subprocess-heavy app can strand, and to make signal handling
# in PID 1 somebody else's solved problem.
ENTRYPOINT ["/sbin/tini", "--"]
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
