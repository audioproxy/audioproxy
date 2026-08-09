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
# priv/ is a *compile-time* input here, not an asset directory: `AudioProxy.Llms`
# reads priv/llms/*.txt into module attributes with `File.read!`, so a build
# missing this line does not produce an image without its docs — it fails to
# compile, in the builder, before anything is packaged. Anything else that
# lands under priv/ inherits the same treatment.
COPY priv priv

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

# procps for the same reason as the runtime stage: the :ffmpeg suite exercises
# the kill discipline, so the stage that runs it needs the same /bin/kill.
RUN apt-get update \
    && apt-get install -y --no-install-recommends build-essential git ffmpeg procps \
    && rm -rf /var/lib/apt/lists/*

WORKDIR /src

RUN mix local.hex --force && mix local.rebar --force

COPY mix.exs mix.lock ./
RUN mix deps.get && mix deps.compile

COPY config config
COPY lib lib
COPY priv priv
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
#
# `procps` is not optional padding: it provides /bin/kill, and the render
# lifecycle signals ffmpeg through `System.find_executable("kill")`. The shell
# builtin does not satisfy that — it needs a real binary. Alpine's busybox
# supplied one, Debian slim does not, and without it a client disconnect or an
# AP_RENDER_TIMEOUT cannot terminate the subprocess: the no-orphan guarantee
# degrades to "ffmpeg exits when it feels like it", holding a CPU slot the whole
# time. AudioProxy.Ffmpeg.Render logs and treats the process as alive rather
# than pretending, so the symptom is a log line and a leak, not a crash.
RUN apt-get update \
    && apt-get install -y --no-install-recommends \
        ca-certificates \
        ffmpeg \
        procps \
        tini \
        wget \
    && rm -rf /var/lib/apt/lists/*

# Corresponding source, baked in at build time.
#
# This image distributes Debian binaries — ffmpeg's build is `--enable-gpl` —
# and distributing a GPL binary carries two obligations: ship the license text,
# and make the *exact* source available. The first is Debian's own
# `/usr/share/doc/<pkg>/copyright`, which debian:slim keeps (its dpkg exclude
# strips `/usr/share/doc/*` but re-includes the copyright files). **Any future
# size pass must preserve them**, along with this manifest; the license-
# compliance job in CI fails the build if either goes missing.
#
# The second is this file. Rather than mirroring tarballs, each package is
# linked to snapshot.debian.org at its installed version — Debian's own archive,
# and version-exact, so the link resolves to the source the binary in *this*
# image was built from rather than to whatever is current. The archive is
# long-lived rather than guaranteed forever; mirroring tarballs is the
# escalation if that ever stops holding.
#
# Generated here rather than by CI on purpose: the artifact carries its own
# compliance, so an image built locally is as compliant as a published one.
#
# `${Package}` and not `${binary:Package}` — the latter appends the arch
# qualifier (`libfoo:amd64`), which is not what the manifest is keyed on. The
# status filter drops packages that are removed-but-config-retained: dpkg still
# knows them, but this image does not distribute them.
#
# Written to a temporary file and moved into place only once it has been counted.
# `set -o pipefail` (dash supports it since 0.5.12, which trixie carries) makes a
# `dpkg-query` that dies mid-stream fail the build rather than being laundered
# into success by the `sort` at the end of the pipe; the count is the backstop
# for the same hazard, because a manifest that is merely *short* is the failure
# that looks fine. The floor is well under the ~90 packages a bare debian:slim
# carries, so it fires on a broken generator and never on a slimmer image.
ARG DEBIAN_VERSION
RUN set -eu; \
    set -o pipefail; \
    snapshot="${DEBIAN_VERSION##*-}"; \
    mkdir -p /usr/share/audioproxy; \
    { \
      echo "# audio_proxy image — corresponding source for the Debian packages it distributes"; \
      echo "#"; \
      echo "# License notices for every package below are in /usr/share/doc/<package>/copyright."; \
      echo "# The source each binary was built from is archived by Debian at the URL on its line;"; \
      echo "# snapshot.debian.org is version-exact, so those links do not drift with the suite."; \
      echo "#"; \
      echo "# This covers what apt installed. The release itself — the BEAM's bundled ERTS and"; \
      echo "# the compiled Elixir dependencies under /app — is Apache-2.0 and MIT throughout,"; \
      echo "# and its source is the repository named in the image labels."; \
      echo "#"; \
      echo "# Base image: debian:${DEBIAN_VERSION}-slim"; \
      case "$snapshot" in \
        [0-9][0-9][0-9][0-9][0-9][0-9][0-9][0-9]) \
          echo "# Nearest archived snapshot to that date tag (the archive resolves it to the"; \
          echo "# closest run, which may be some hours either side — the per-package URLs below"; \
          echo "# are the exact record, this one is context):"; \
          echo "#   https://snapshot.debian.org/archive/debian/${snapshot}T000000Z/";; \
        *) \
          echo "# Nearest archived snapshot: unknown (DEBIAN_VERSION carries no date suffix)";; \
      esac; \
      echo "#"; \
      echo "# Packages installed at build time may be newer than that snapshot; the per-package"; \
      echo "# URLs are the authoritative record, and each is pinned to the version listed here."; \
      echo "#"; \
      echo "# package<TAB>version<TAB>source-package<TAB>source-version<TAB>source-url"; \
      dpkg-query -W -f='${db:Status-Abbrev}\t${Package}\t${Version}\t${source:Package}\t${source:Version}\n' \
        | awk -F'\t' '$1 ~ /^ii/ { printf "%s\t%s\t%s\t%s\thttps://snapshot.debian.org/package/%s/%s/\n", $2, $3, $4, $5, $4, $5 }' \
        | sort; \
    } > /tmp/SOURCES.txt; \
    packages=$(grep -cv '^#' /tmp/SOURCES.txt || true); \
    echo "manifest lists $packages packages"; \
    if [ "$packages" -lt 50 ]; then \
      echo "manifest lists only $packages packages — dpkg-query or awk failed" >&2; \
      exit 1; \
    fi; \
    mv /tmp/SOURCES.txt /usr/share/audioproxy/SOURCES.txt

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
#
# The description is what GHCR prints on the package page, so it is where the
# compliance pointer goes: someone deciding whether to redistribute this image
# reads that page, not the filesystem.
#
# `licenses` is **not an inventory** and cannot be one: the image also carries
# GPL-2+, LGPL, MPL, MIT and BSD packages, and an SPDX expression naming all of
# them would be a hand-maintained list that goes stale on the next apt bump. It
# names the proxy's own Apache-2.0 and the strongest copyleft in the aggregate
# (Debian's ffmpeg copyright carries GPL-3+ stanzas), on the grounds that a
# scanner which under-reports copyleft fails worse than one that over-reports.
# The authoritative record is SOURCES.txt and the copyright files, which the
# description points at.
ARG VERSION
ARG REVISION
LABEL org.opencontainers.image.title="audio_proxy" \
      org.opencontainers.image.description="On-the-fly audio transcoding proxy. Distributes Debian packages, ffmpeg among them, under their own licenses: notices are in /usr/share/doc/*/copyright and corresponding source is listed in /usr/share/audioproxy/SOURCES.txt. See https://github.com/audioproxy/audioproxy#license" \
      org.opencontainers.image.licenses="Apache-2.0 AND GPL-3.0-or-later" \
      org.opencontainers.image.source="https://github.com/audioproxy/audioproxy" \
      org.opencontainers.image.url="https://github.com/audioproxy/audioproxy" \
      org.opencontainers.image.version="${VERSION}" \
      org.opencontainers.image.revision="${REVISION}"
