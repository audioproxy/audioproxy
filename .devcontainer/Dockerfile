# Elixir/OTP pinned to the same pair as .tool-versions. ffmpeg and ffprobe are
# of the dev image because they are part of the product: the render pipeline
# shells out to them, so tests tagged :ffmpeg need the real binaries.
FROM hexpm/elixir:1.20.2-erlang-28.5.0.4-debian-trixie-20260713-slim

ENV LANG=C.UTF-8 \
    MIX_HOME=/home/dev/.mix \
    HEX_HOME=/home/dev/.hex \
    DEBIAN_FRONTEND=noninteractive

RUN apt-get update \
    && apt-get install -y --no-install-recommends \
        build-essential \
        ca-certificates \
        curl \
        ffmpeg \
        git \
        inotify-tools \
        locales \
        procps \
        ripgrep \
    && rm -rf /var/lib/apt/lists/*

# Non-root user with uid/gid 1000 so bind-mounted files keep host ownership.
RUN groupadd --gid 1000 dev \
    && useradd --uid 1000 --gid 1000 --create-home --shell /bin/bash dev

USER dev
WORKDIR /workspaces/audio_proxy

RUN mix local.hex --force && mix local.rebar --force
