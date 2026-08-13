# audio_proxy

[![CI](https://github.com/audioproxy/audioproxy/actions/workflows/ci.yml/badge.svg)](https://github.com/audioproxy/audioproxy/actions/workflows/ci.yml)
[![Hex.pm](https://img.shields.io/hexpm/v/audio_proxy.svg)](https://hex.pm/packages/audio_proxy)
[![Documentation](https://img.shields.io/badge/docs-audioproxy.dev-purple.svg)](https://docs.audioproxy.dev)

Transcode audio on demand, from a URL.

Point it at your audio and ask for a variant by URL: a 30-second preview, a mono file for speech-to-text, a normalised podcast MP3, a 24-bit FLAC excerpt. The options are in the path, so one master can serve all of them and you generate none of them in advance. If you know [imgproxy](https://imgproxy.net), this is that, for audio.

**Full documentation: [docs.audioproxy.dev](https://docs.audioproxy.dev)**, covering how to render, sign, configure, deploy and observe.

> **Status: early, `v0.6.0`.** Transcoding works end to end and you can try it in about a minute. Sources live on a mounted directory or in S3-compatible object storage. With a variant store configured, local or `s3://`, completed renders are kept and served back with `Range` support, so a variant is encoded once rather than per request. See the [Roadmap](#roadmap).

## Quick start

Point it at a directory of audio you already have. No signing key, no bucket, no config file.

```bash
docker run --rm -p 4000:4000 \
  -e AP_ALLOW_INSECURE=true \
  -e AP_LOCAL_ROOT=/audio \
  -v /path/to/your/audio:/audio:ro \
  ghcr.io/audioproxy/audioproxy:0.6.0
```

> On Apple Silicon, add `--platform linux/amd64`. The image is x86-64 only for now and runs under emulation; arm64 is [its own slice](https://github.com/audioproxy/audioproxy/tree/main/openspec/changes/add-multi-arch-images).

Now ask for a variant, from another shell. `SRC` names a file *relative to the directory you mounted*, so `track.wav` means `/path/to/your/audio/track.wav`:

```bash
BASE=localhost:4000
SRC='plain/local://track.wav'

# A 30-second preview: Opus at 96 kbps, fading in and out.
curl -o preview.opus "$BASE/insecure/f:opus/br:96/t:0:30/fade:1:1/$SRC"

# The same source as a small mono MP3, the shape speech wants.
curl -o speech.mp3 "$BASE/insecure/f:mp3/br:64/ch:1/sr:22050/$SRC"

# Waveform peaks to draw a player UI, 800 min/max pairs as JSON.
curl "$BASE/insecure/f:peaks/pts:800/$SRC"
```

Each response starts arriving while ffmpeg is still encoding: it is chunked, not buffered to disk first. Change any option and you have a different variant, with no server-side configuration to add. The URL is the whole request.

Two things that matter beyond a first try:

- **`AP_ALLOW_INSECURE` is development only.** It is what lets the literal `insecure` stand in for a signature, so while it is on, anyone who can reach the port can render anything under `AP_LOCAL_ROOT`. Real deployments sign every URL.
- **Mount the directory read-only** (`:ro`, above). Write access to `AP_LOCAL_ROOT` is write access to what the proxy will serve.

The [quickstart guide](https://docs.audioproxy.dev/start/quickstart/) has the same thing at more length, plus a browser player. [Transforms](https://docs.audioproxy.dev/guides/transforms/) is every option the URL accepts, arranged by what you are trying to do.

## Design

Sources live on a mounted directory, in S3, or in any HTTP-reachable store. Variants (transcodes, trimmed previews, waveform peaks) are rendered on demand by ffmpeg, streamed to the first requester as they encode, and teed to a variant bucket, so later requests for the same variant redirect to object storage and get `Range` support and byte-serving for free.

URLs are the entire API: no request bodies, no server-side state. Every variant is fully described by its processing options, which double as its cache key, and every URL is signed.

```
GET /{signature}/{options}/{source}
```

**[`docs/audio-proxy-api-v1.md`](docs/audio-proxy-api-v1.md) is the source of truth** for the URL grammar, processing options, cache-key rules, response headers and error codes. The [Roadmap](#roadmap) says which parts of it exist today.

## Running it

The container is the way to run this. It carries the release with its own Erlang runtime and the ffmpeg the renders are tested against, so there is nothing to install and nothing to keep in step. A real deployment drops `AP_ALLOW_INSECURE` and gives the proxy a key and salt instead:

```bash
docker run --rm -p 4000:4000 \
  -e AP_KEY="$AP_KEY" -e AP_SALT="$AP_SALT" \
  -e AP_LOCAL_ROOT=/audio \
  -e AP_VARIANT_STORE=file:///var/cache/audio_proxy \
  -e AP_SERVE_MODE=proxy \
  -v /path/to/your/audio:/audio:ro \
  -v audioproxy-cache:/var/cache/audio_proxy \
  ghcr.io/audioproxy/audioproxy:0.6.0
```

**Pin a version.** `:0.6.0` and `:sha-<commit>` name an exact image; `:0.6` follows patch releases; `:latest` and `:edge` move under you. Pinning matters more here than for most services, because a different ffmpeg encodes the same URL to different bytes, which is also why a pin bump always cuts a release. The pinned versions are in [VERSIONS.md](VERSIONS.md).

To run it from a checkout instead, for development or to build your own image:

```bash
mise install          # Elixir and Erlang/OTP, pinned in .tool-versions
mix deps.get
PORT=4000 mix run --no-halt
```

That path needs `ffmpeg` and `ffprobe` on `PATH`. See [docs/development.md](https://github.com/audioproxy/audioproxy/blob/main/docs/development.md) for a development container that already has them, and for the test suite.

The proxy is also published to hex as an OTP application (`{:audio_proxy, "~> 0.6"}`), so it can run inside a BEAM node you already deploy. It is an application rather than a library: adding the dependency is the whole integration, and starting it reads the `AP_*` environment, binds two listeners, and expects ffmpeg on `PATH`. The [configuration reference](https://docs.audioproxy.dev/reference/api-v1/) covers what that commits you to.

## Roadmap

No dates. It is built in small releases, each one usable, in roughly this order.

**Working now (`v0.6.0`)**

- Signed URLs, the full processing-options grammar, and the cache-key rules
- Expiring URLs: `exp:<unix-seconds>` time-boxes one URL without rotating the key, and because it is not part of the cache key, minting a fresh short-lived URL per page view still resolves to one render
- Transcoding to MP3, AAC/M4A, Opus, Vorbis, FLAC and WAV, with trimming, fades, loudness normalisation, channel and sample-rate control
- Renders stream while they encode, and concurrent requests for the same variant share one render
- Sources on a mounted directory or in S3, read by ffmpeg through a presigned URL, so a trim fetches only the bytes it needs
- A variant store on a local directory or in S3, so the cache survives a restart and is shared between nodes, and with it `AP_SERVE_MODE=redirect`. The store can carry its own `AP_VARIANT_S3_*` credentials and endpoint, so sources and variants may live with different providers or under different principals
- `f:peaks`, waveform min/max data in audiowaveform's JSON and binary formats
- A cap on simultaneous renders with a bounded wait queue, so a burst queues and then sheds rather than thrashing the machine
- `GET /info` for source metadata, `GET /ready` for queue-aware readiness, and a Prometheus `GET /metrics` on a bind-restricted listener of its own
- Video input refused rather than transcoded, enforced rather than intended
- Optional CORS (`AP_ALLOW_ORIGIN`), off by default
- A single container, published per release, and the package on hex

**After that:** HTTPS sources, for stores that are not S3; arm64 images, so Graviton/Ampere and Apple Silicon run natively.

**Under consideration:** a `/sync/` URL that renders fully before responding, trading time-to-first-byte for a seekable first play. Still open, because warming the cache does the same job for nothing: fetch the URL once, discard it, then set `src`.

**Deliberately not planned:** video. This is an audio proxy and refuses video input rather than becoming a general ffmpeg gateway; video transcoding is far more expensive and carries most of ffmpeg's CVE history.

**Wanted, but not designed yet:** HLS and segmented streaming. A v2 goal rather than a rejected one, and the URL space is reserved. The unsolved part is gapless boundaries, since encoding each segment independently gives each one its own encoder priming.

`0.x` means the URL contract can still change. It will settle at `1.0`, after which a change to what an existing URL means, or to how cache keys are derived, is a major version. The per-slice detail, including rationale and trade-offs, lives in [`openspec/changes/`](https://github.com/audioproxy/audioproxy/tree/main/openspec/changes).

## Documentation

Start at **[docs.audioproxy.dev](https://docs.audioproxy.dev)**. It is the goal-first documentation: how to render a variant, sign a URL, configure the proxy, choose a provider, and run more than one node.

| Document | What it covers |
|---|---|
| [docs.audioproxy.dev](https://docs.audioproxy.dev) | **Start here.** Quickstart, transforms, sources, rendering, S3 providers, scaling, capacity, Rails |
| [docs/audio-proxy-api-v1.md](docs/audio-proxy-api-v1.md) | **The source of truth.** URL grammar, every processing option, cache-key rules, response headers, error codes |
| [llms.txt](llms.txt), [llms-full.txt](llms-full.txt) | The same contract as markdown, in one file, checked against the code. See [For AI agents](#for-ai-agents) |
| [docs/development.md](https://github.com/audioproxy/audioproxy/blob/main/docs/development.md) | Toolchain, per-slice worktrees and devcontainers, the test suite and its tags, CI, how a release is cut |
| [docs/ffmpeg-arguments.md](docs/ffmpeg-arguments.md) | How options become ffmpeg arguments: filter order, per-format flags, known gaps |
| [docs/operations.md](docs/operations.md) | Reading a running proxy: the request log and its levels, every exported metric, scrape config, the four signals to alert on |
| [docs/](https://github.com/audioproxy/audioproxy/tree/main/docs) | The authored-from upstream for the site's guide pages: sources, rendering, scaling, capacity, s3-providers |
| [VERSIONS.md](VERSIONS.md) | What the image is built from: Debian, Elixir/OTP and ffmpeg pins, why not Alpine, and how to bump one |
| [examples/](https://github.com/audioproxy/audioproxy/tree/main/examples) | A one-file browser player for trying variants, and why it has to be served rather than opened |
| `openspec/` | `specs/` holds the capabilities that are built; `changes/` holds what is planned |

## For AI agents

Two files at the repository root carry the API reference as markdown, per the [llms.txt](https://llmstxt.org) convention: [`llms.txt`](llms.txt) is the index, and [`llms-full.txt`](llms-full.txt) is the whole reference in one document. Point an agent at `llms-full.txt` and it has everything it needs to construct correct signed URLs; nothing else has to be fetched. They also ride in the hex package, so an embedder finds them in the dependency tree.

**Read them at the tag you are running.** `GET /health` reports the version, so `curl -s $BASE/health` and then reading these files at that tag gives you documentation matched to the deployment in front of you. That matters while the URL contract is still `0.x`.

Four things in `llms-full.txt` are machine-checked rather than trusted: the set of option keys, against the parser; the set of error codes, against the error mapping; the set of environment variables, against the ones `AudioProxy.Config` reads; and the worked signing example, recomputed from the signer on every run. A new option, error code or variable that goes undocumented fails CI. The rest, meaning value ranges, the defaults themselves and the prose, is reviewed rather than enforced.

## Stack

Elixir with Plug and [Bandit](https://github.com/mtrudel/bandit), and no Phoenix, because there is no HTML to render and no channels to serve. ffmpeg runs as a subprocess rather than through libav bindings, so it does all decoding and encoding while Elixir stays orchestration; `ffprobe` backs `/info`. There is no database, no queue and no sidecar, because the only state is what lives in S3 and in the URLs themselves. That leaves one container to deploy and nothing to migrate.

## License

[Apache-2.0](LICENSE) for the proxy itself. ffmpeg is invoked as a subprocess, so nothing about its licensing reaches this source tree.

The published image is a separate question, because it is a distribution. It ships Debian's packages, ffmpeg among them, and Debian builds ffmpeg with `--enable-gpl`; handing those binaries to someone carries the GPL's obligations. Two things ride in the image to meet them:

- **The license notices**, at `/usr/share/doc/<package>/copyright`, exactly as Debian ships them.
- **The corresponding source**, listed in `/usr/share/audioproxy/SOURCES.txt`: every Debian package the image installs, at its exact version, with the [snapshot.debian.org](https://snapshot.debian.org) URL for the source that binary was built from. That archive is version-exact and long-lived, so a link still resolves to the source behind *this* image after the suite has moved on. (The manifest covers what apt installed. The release alongside it, the bundled ERTS and the Elixir dependencies, is Apache-2.0 and MIT throughout, and its source is this repository.)

Read either straight out of the image:

```bash
docker run --rm --entrypoint cat ghcr.io/audioproxy/audioproxy:latest /usr/share/audioproxy/SOURCES.txt
docker run --rm --entrypoint cat ghcr.io/audioproxy/audioproxy:latest /usr/share/doc/ffmpeg/copyright
```

Both are checked in CI on every build (present, complete, and resolving), so an image that reaches the registry has them. The image's `org.opencontainers.image.licenses` label names Apache-2.0 and the strongest copyleft in the mix; it is a signal, not an inventory, and those two files are the record.

Should a listed source ever become unreachable, the offer stands: open an issue at [github.com/audioproxy/audioproxy](https://github.com/audioproxy/audioproxy/issues) and the corresponding source for that image will be provided, for three years from the date it was published.

Redistributing your own image built from this one inherits all of the above; keep `/usr/share/doc` and the manifest intact and it travels with the layers. Patents are a separate axis from licensing, and AAC in particular is still encumbered. If you offer `f:aac` or `f:m4a` commercially, that is worth its own opinion.
