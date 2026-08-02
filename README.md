# audio_proxy

[![CI](https://github.com/audioproxy/audioproxy/actions/workflows/ci.yml/badge.svg)](https://github.com/audioproxy/audioproxy/actions/workflows/ci.yml)

An imgproxy-style on-the-fly audio transcoding proxy.

> **Status: early.** A signed URL for a `local://` source now renders and
> streams: URL signing, the processing-options grammar, the ffmpeg argument
> builder, source resolution and the chunked render endpoint are done. The
> variant cache (so every request still renders), S3 and HTTPS sources, peaks
> and `/info` are not. Slices tracked under `openspec/changes/`.

## Quick start

Point it at a directory of audio you already have. No signing key, no bucket,
no config file.

```bash
docker run --rm -p 4000:4000 \
  -e AP_ALLOW_INSECURE=true \
  -e AP_LOCAL_ROOT=/audio \
  -v /path/to/your/audio:/audio:ro \
  ghcr.io/audioproxy/audioproxy:0.1.0
```

> On Apple Silicon, add `--platform linux/amd64`. The image is x86-64 only for
> now and runs under emulation; arm64 is [its own
> slice](openspec/changes/add-multi-arch-images).

Then, in another shell — `SRC` names a file *relative to the directory you
mounted*, so `track.wav` means `/path/to/your/audio/track.wav`:

```bash
BASE=localhost:4000
SRC='plain/local://track.wav'

curl -s "$BASE/health"
# {"status":"ok","version":"0.1.0"}

# A 30-second preview: Opus at 96 kbps, fading in and out.
curl -o preview.opus "$BASE/insecure/f:opus/br:96/t:0:30/fade:1:1/$SRC"

# The same source as a small mono MP3, the shape speech wants.
curl -o speech.mp3 "$BASE/insecure/f:mp3/br:64/ch:1/sr:22050/$SRC"
```

Both start arriving while ffmpeg is still encoding — the response is chunked,
not buffered to disk first. Change any option and you have a different variant,
with no server-side configuration to add: the URL is the whole request.

Two things that matter beyond a first try:

- **`AP_ALLOW_INSECURE` is development only.** It is what lets the literal
  `insecure` stand in for a signature, so while it is on, anyone who can reach
  the port can render anything under `AP_LOCAL_ROOT`. [Signing
  URLs](#signing-urls) is the real thing.
- **Mount the directory read-only** (`:ro`, above). Write access to
  `AP_LOCAL_ROOT` is write access to what the proxy will serve.

[Running it](#running-it) has the shape you would actually deploy.

## What you can do with it

Point it at a lossless master — a file in a directory you mounted, or later an
S3 object — and ask for a variant by URL. Nothing is pre-rendered and nothing
is configured server-side: the options in the path *are* the request, so a
catalogue of one file can serve previews, waveforms, speech-ready mono and
format-shifted downloads without you generating any of them in advance.
The path is `/{signature}/{options}/{source}`. These examples use the literal
`insecure` in place of a signature, which `AP_ALLOW_INSECURE=true` accepts in
development; [Signing URLs](#signing-urls) covers the real thing.

```bash
BASE=localhost:4000
SRC='plain/local://piece.wav'    # AP_LOCAL_ROOT/piece.wav
# A 30-second preview: Opus at 96 kbps, starting 12.5 s in,
# half-second fade in and one-second fade out.
curl "$BASE/insecure/f:opus/br:96/t:12.5:30/fade:0.5:1/$SRC"

# Waveform peaks to draw a player UI — 800 min/max pairs as JSON.
curl "$BASE/insecure/f:peaks/pts:800/$SRC"

# Speech, small: 64 kbps mono MP3 at 22.05 kHz.
curl "$BASE/insecure/f:mp3/br:64/ch:1/sr:22050/$SRC"

# Normalised to −16 LUFS for podcast delivery.
curl "$BASE/insecure/f:mp3/br:128/norm:ebu/$SRC"

# Two minutes of 24-bit FLAC, offered to the browser as a download.
curl -OJ "$BASE/insecure/f:flac/bd:24/t:60:120/dl:excerpt.flac/$SRC"

# Mono 16 kHz WAV, the shape a speech-to-text pipeline wants.
curl "$BASE/insecure/f:wav/ch:1/sr:16000/$SRC"

# What is this file? (ffprobe metadata, as JSON)
curl "$BASE/insecure/info/$SRC"
```

Each URL describes its output completely, so the same URL always means the
same bytes. The first request for a variant renders it and streams it while it
encodes; later requests are served from the variant bucket with `Range` support.

> **Mostly real now.** Transcodes render and stream: point `AP_LOCAL_ROOT` at a
> directory and the first six examples above return audio. Not yet: `f:peaks`
> and `info` (their own slices), `s3://` and `https://` sources, and the
> variant bucket — every request renders, because there is no cache to hit
> yet. Each option string above is checked against the parser in the test
> suite.

## Design

Sources live on a mounted directory, in S3, or in any HTTP-reachable store. Variants — transcodes, trimmed
previews, waveform peaks — are to be rendered on demand by ffmpeg, streamed to
the first requester as they encode, and teed to a variant bucket, so that later
requests for the same variant redirect to S3 and get `Range` support and
byte-serving for free.

URLs are the entire API: no request bodies, no server-side state. Every variant
is fully described by its processing options, which double as its cache key, and
every URL is signed.

```
GET /{signature}/{options}/{source}
```

**[`docs/audio-proxy-api-v1.md`](docs/audio-proxy-api-v1.md) is the source of
truth** for the URL grammar, processing options, cache-key rules, response
headers, and error codes. What follows here is the working subset; reach for
the spec when you need the exact contract.

## Running it

The container is the way to run this. It carries the release with its own
Erlang runtime and the ffmpeg the renders are tested against, so there is
nothing to install and nothing to keep in step.

The [Quick start](#quick-start) above runs it unsigned, for a first look. The
difference in a real deployment is that `AP_ALLOW_INSECURE` is gone and a key
and salt take its place:

```bash
docker run --rm -p 4000:4000 \
  -e AP_KEY="$AP_KEY" -e AP_SALT="$AP_SALT" \
  -e AP_LOCAL_ROOT=/audio \
  -v /path/to/your/audio:/audio:ro \
  ghcr.io/audioproxy/audioproxy:0.1.0
```

That is the whole configuration for serving files off a mounted directory — no
credentials, no bucket, no database.

**Pin a version.** `:0.1.0` and `:sha-<commit>` name an exact image; `:0.1`
follows patch releases; `:latest` and `:edge` move under you, and `:edge` is
whatever last landed on `main`. Pinning matters more here than for most
services, because a different ffmpeg encodes the same URL to different bytes —
which is also why a pin bump always cuts a release. The pinned versions are in
[VERSIONS.md](VERSIONS.md).

To run it from a checkout instead — for development, or to build your own
image:

```bash
mise install          # Elixir and Erlang/OTP, pinned in .tool-versions
mix deps.get
PORT=4000 mix run --no-halt
```

That path needs `ffmpeg` and `ffprobe` on `PATH`. For a development container
that already has them, and for the test suite, see
[docs/development.md](docs/development.md).

## Signing URLs

Every URL is signed: the first path segment is
`base64url(HMAC-SHA256(key, salt ‖ rest-of-path))`, computed over the exact
bytes after the signature segment, leading `/` included, taken from the raw
(still percent-encoded) request path. Key and salt are the hex-decoded values
of `AP_KEY`/`AP_SALT`. Signatures are emitted unpadded; the canonical padded
form is accepted on verification, but non-canonical spellings (over-padding,
variant final characters) are rejected — a signature cannot be respelled.

`AudioProxy.Signature.sign/3` is the reference signer:

```elixir
key  = Base.decode16!("00112233445566778899AABBCCDDEEFF00112233445566778899AABBCCDDEEFF")  # AP_KEY
salt = Base.decode16!("FFEEDDCCBBAA99887766554433221100")  # AP_SALT
rest = "/f:opus/br:96/plain/s3://masters/2026/piece-final.wav"

AudioProxy.Signature.sign(rest, key, salt)
# => "zfLTfPPhQ8kdeYYJOdagqPfog2nFk7KzDFUjtRAf_Ns"
```

→ the URL is `/<signature><rest>`, i.e.
`/zfLTfPPhQ8kdeYYJOdagqPfog2nFk7KzDFUjtRAf_Ns/f:opus/br:96/plain/s3://masters/2026/piece-final.wav`.

Sign the URL-escaped path exactly as it will be requested — verification runs
over the raw request path, so re-encoding anything breaks the signature: a
key with a space must appear as `a%20track.wav` in both the signature input
and the request (or use the `enc/` source form, which exists precisely to
avoid escaping headaches). For non-Elixir clients, the same three lines in
Ruby:

```ruby
require "openssl"
require "base64"

key  = "00112233445566778899AABBCCDDEEFF00112233445566778899AABBCCDDEEFF"  # AP_KEY (hex)
salt = "FFEEDDCCBBAA99887766554433221100"  # AP_SALT (hex)
path = "/f:opus/br:96/plain/s3://masters/2026/piece-final.wav"

sig = Base64.urlsafe_encode64(
  OpenSSL::HMAC.digest("SHA256", [key].pack("H*"), [salt].pack("H*") + path),
  padding: false
)
# => "zfLTfPPhQ8kdeYYJOdagqPfog2nFk7KzDFUjtRAf_Ns"
```

Generate a real key with `openssl rand -hex 32` — `AP_KEY` must decode to at
least 32 bytes or the proxy refuses to boot. **The key above is a published
test vector** used throughout the test suite; never use it as a real key.

> **Dev mode — never enable in production.** Setting `AP_ALLOW_INSECURE=true`
> makes the literal segment `insecure` pass as a signature
> (`/insecure/f:opus/…/plain/…`). It exists for local development and smoke
> tests; with it on, anyone who can reach the proxy can render anything.

## Rendering a variant

End to end, with a directory of your own audio and a real signature:

```bash
export AP_KEY=$(openssl rand -hex 32)
export AP_SALT=$(openssl rand -hex 16)
export AP_LOCAL_ROOT=/path/to/your/audio
PORT=4000 mix run --no-halt &
```

Sign the path — everything after the signature segment, leading `/` included —
and request it:

```bash
REST='/f:mp3/br:128/t:0:30/plain/local://piece.wav'

SIG=$(ruby -ropenssl -rbase64 -e '
  print Base64.urlsafe_encode64(
    OpenSSL::HMAC.digest("SHA256", [ENV["AP_KEY"]].pack("H*"),
                         [ENV["AP_SALT"]].pack("H*") + ARGV[0]),
    padding: false)' "$REST")

curl -D - -o preview.mp3 "localhost:4000/$SIG$REST"
```

```
HTTP/1.1 200 OK
transfer-encoding: chunked
content-type: audio/mpeg
cache-control: public, max-age=31536000, immutable
etag: "6f1c…"
x-audio-proxy: MISS
```

The first bytes leave before ffmpeg has finished, so a long transcode starts
playing immediately rather than after it completes. There is no
`Content-Length` and no `Accept-Ranges` on this response: the length is not
known when the head goes out, and ranges arrive with the variant cache, whose
`HIT` redirects to storage that serves them natively.

`x-audio-proxy: MISS` is currently on every response, because there is no cache
to hit yet — each request renders. `etag` is the variant's cache key, which is
a pure function of the normalized options and the source, so the same variant
requested with its options in a different order carries the same one.

If the client goes away mid-stream, the render goes with it: closing the
connection kills the ffmpeg process rather than leaving it encoding into a
socket nobody is reading. A render that fails *before* any bytes are sent is
one of the JSON errors below; one that fails after them can only be signalled
by cutting the connection short, so treat a chunked response that ends without
its terminating chunk as a failed download.

For what happens behind that — the subprocess, buffering, the timeout and the
kill discipline — see [docs/rendering.md](docs/rendering.md).

## Processing options

The options segments describe the variant completely, and their normalized
form *is* the cache key. `AudioProxy.Options` parses, validates, and normalizes
them; `AudioProxy.CacheKey` hashes the result. Invalid or conflicting options
are rejected with an `AudioProxy.OptionError` naming the offending segment,
which the HTTP layer will render as a `422`.

```elixir
{:ok, opts} = AudioProxy.Options.parse("f:opus/br:96/t:12.5:30/fade:0.5:1")
AudioProxy.Options.normalize(opts)
# => "br:96/f:opus/fade:0.5:1/t:12.5:30"

AudioProxy.CacheKey.derive!("br:96/f:opus", "s3://masters/piece.wav")
# => "00d89ba1cbfecacd4450ae5ca912f7153f4740bb5e81d96609f6bfdfbfde4099"
```

### Supported options

| Key | Value | Notes |
|---|---|---|
| `f` | `mp3` `opus` `ogg` `aac` `m4a` `flac` `wav` `peaks` | Output format; default `mp3` |
| `br` | positive integer, kbps | CBR/ABR bitrate; excludes `q` |
| `q` | number | VBR quality; excludes `br` |
| `sr` | positive integer, Hz | Resample; default is the source rate. An explicit `sr` above 48 kHz is rejected for lossy formats; capping the *default* for lossy sources is the renderer's job (§3.1) |
| `ch` | `1` \| `2` | Downmix |
| `bd` | `16` \| `24` \| `32f` | Bit depth, lossless formats only |
| `t` | `start[:duration]`, seconds | Trim. `t:30` runs to the end; `t:30:15` is 15 s from 30 s |
| `fade` | `in[:out]`, seconds | Applied inside the trimmed region; an omitted out-fade is `0` |
| `gain` | signed number, dB | Static gain |
| `norm` | `ebu[:I[:TP[:LRA]]]` | Loudness normalization; targets default to `-16:-1.5:11`. v1 runs `loudnorm` single-pass — good enough for previews, not for masters (§3.2) |
| `pts` | positive integer | Peaks: number of min/max pairs; default `800` |
| `pk_fmt` | `json` \| `dat` | Peaks: output encoding; default `json` |
| `dl` | filename | Sets `Content-Disposition: attachment` |
| `cb` | opaque string | Cache-buster; participates in the cache key |

Decimals are accepted to three places (millisecond precision) and rejected
beyond that rather than silently rounded, so float formatting can never
destabilize a cache key. `-0` is collapsed to `0` at parse time: it renders as
`0`, so it cannot be told apart in a cache key, and letting it into the struct
would let it be told apart in the ffmpeg arguments. `dl` and `cb` values stay
percent-encoded and are treated as opaque bytes.

### Validation rules

Beyond each key's own value domain, these cross-key rules are enforced:

- `br` and `q` are mutually exclusive.
- `br` requires a lossy format; `q` requires a format whose encoder has a
  quality scale (everything but `wav`).
- `bd` requires a lossless format (`flac`, `wav`), and `bd:32f` requires
  `f:wav` — flac encodes integer samples only.
- `q` must sit inside its codec's scale: mp3 0–9, ogg −1–10, aac/m4a 0.1–2,
  opus 0–10, flac 0–12. `f:flac/q:13` is refused by ffmpeg itself
  ("invalid compression level"), so refusing it here turns a 500 into a 422.
- `pts` and `pk_fmt` require `f:peaks`.
- `sr` is capped at 48 kHz for lossy formats.
- A fade must fit inside the trimmed region when the trim is bounded, and a
  fade-out requires a bounded trim at all: its start is `duration - out`, and
  without a duration there is nothing to count back from. A fade-in needs no
  trim, since it starts at zero.

Peaks add one more: `f:peaks` refuses `br`, `q`, `sr`, `bd`, `gain` and
`norm`. Peaks are computed from the decoded source and respect only `t`, `ch`
and `fade` (§3.3), so accepting an option that cannot change the output would
hand byte-identical peaks two different cache keys. `f:peaks/br:96` is a 422.

The rules about `br`, `q` and `bd:32f` come from the same principle applied
one layer down: ffmpeg accepts `-b:a` on a flac encode and ignores it, so
`f:flac/br:320` would be two cache keys for one file. Rejecting is cheaper
than storing the duplicate.

Unknown keys, repeated keys, empty segments, and valueless segments are
rejected too — there is no last-write-wins and no silent ignoring, because
either would let two different URLs mean the same variant. Values are also
bounded above (`br` ≤ 10000, `sr` ≤ 384000, `pts` ≤ 100000, `|gain|` ≤ 100)
so a mistyped URL fails here as a 422 rather than downstream as a render
error, and `dl`/`cb` reject control characters — that last rule is what makes
the cache key's separator sound (see below).

### Cache-key semantics

```
lowercase-hex(SHA-256(normalized-options ‖ "\n" ‖ canonical-source))
```

Normalization is what makes this deterministic: keys are sorted
lexicographically, applicable defaults are materialized (`f`, the `norm`
targets when `norm` is present, `pts`/`pk_fmt` under `f:peaks`), and every
number is rendered minimally (`30`, never `30.0`). So `f:opus/br:96` and
`br:96/f:opus` are one variant with one key, while any genuine difference —
`cb` included — yields a different one. The `"\n"` is load-bearing: without
it, `("", "/gain:3")` and `("gain:3", "")` would hash identical bytes, which
is why control characters are refused in the only two options whose values
are opaque.

Normalization is syntactic, not semantic: `t:0`, `fade:0:0` and `gain:0` are
identity renders but keep their own keys, so those spellings cost duplicate
cache objects. Collapsing them is tracked as follow-up work. The property suite
(`test/audio_proxy/options_property_test.exs`) holds this line: normalization
is idempotent, order-insensitive, and always re-parses.

## Sources

The last portion of the path names what to render, in one of two forms:

| Form | Example |
|---|---|
| `plain/{source}` | `plain/s3://masters/2026/piece-final.wav` |
| `enc/{base64url(source)}` | `enc/czM6Ly9tYXN0ZXJzLzIwMjYvcGllY2UtZmluYWwud2F2` |

Both name the same thing and produce the same cache key. `enc/` exists
because escaping a URL inside a URL is easy to get wrong: base64url the
source as written and you are done.

In the `plain/` form the source is percent-escaped, and it is unescaped
exactly once. A space is `%20`, a literal percent is `%25`, and `+` is a
literal plus. One consequence to watch: a source that already carries
escapes has to be escaped *again*, so a URL ending in `a%20b.wav` is written
`plain/https://h/a%2520b.wav`. Sign the source in the same spelling you
request it in — the signature covers the raw path.

### `local://` — files under a configured root

`local://{path}` serves a path relative to `AP_LOCAL_ROOT`. Mount the directory
you want served, read-only, and point the proxy at it:

```bash
docker run -p 4000:4000 \
  -e AP_ALLOW_INSECURE=true \
  -e AP_LOCAL_ROOT=/srv/audio \
  -v /path/to/your/audio:/srv/audio:ro \
  ghcr.io/audioproxy/audioproxy:0.1.0

# …renders /srv/audio/previews/track.wav
curl "$BASE/insecure/f:mp3/br:128/plain/local://previews/track.wav"
```

Unset `AP_LOCAL_ROOT` and local sources are refused outright: the root is the
whole access-control story for disk. **Mount it read-only** — write access to
the root is equivalent to choosing what the proxy will serve.

[docs/sources.md](docs/sources.md#local-sources) has the confinement rules, the
path limits, and why the root never appears in a cache key.

**`s3://` and `https://` sources are not built yet** — each is its own slice,
with its own rule for what it will serve, and until they land those schemes
are refused as unknown. See [docs/sources.md](docs/sources.md) for the
contract they plug into and `openspec/changes/` for which slice adds which.

## Errors

Failures are JSON, one shape everywhere: `{"error": "…", "message": "…"}`.

| Status | `error` | When |
|---|---|---|
| `401` | `invalid_signature` | Missing or invalid signature |
| `404` | `not_found` | The source is missing, unreadable, unparseable, or not one this proxy may serve — deliberately indistinguishable, so a `404` tells you nothing about what exists on disk |
| `413` | `source_too_large` | The source exceeds `AP_MAX_SRC_BYTES` |
| `415` | `undecodable_source` | The source format is not decodable |
| `422` | `invalid_options` | Invalid or conflicting options; the message names the offending segment |
| `429` | `queue_full` | The render queue is full; `Retry-After` is set |
| `500` | `render_failed` | The render failed for a reason that is not yours: no encoder on the host, no disk space, a failure the proxy could not classify. Worth retrying |
| `504` | `render_timeout` | The render exceeded `AP_RENDER_TIMEOUT` |

All of these are reachable except `429`, which arrives with the render queue
(`openspec/changes/add-render-semaphore`). A failure *after* the response has
begun is not in this table and cannot be: see [Rendering a
variant](#rendering-a-variant).

## Configuration

All configuration comes from `AP_`-prefixed environment variables — see
`docs/audio-proxy-api-v1.md` §6 for intent and `AudioProxy.Config` for parsing.
Values are read, typed, and validated once at boot; a malformed value aborts
startup with an error naming the variable.

Note that the variables below are the full configuration surface for the design,
so several of them are parsed and validated but not yet consumed by anything.

| Variable | Type | Default | Purpose |
|---|---|---|---|
| `AP_KEY` | hex, ≥ 32 bytes decoded | unset | HMAC key for URL signatures |
| `AP_SALT` | hex | unset | HMAC salt |
| `AP_ALLOW_INSECURE` | boolean | `false` | Accept unsigned URLs (dev only) |
| `AP_SOURCE_ALLOWLIST` | comma-separated | empty | Permitted source buckets/hosts (used once remote source types land) |
| `AP_LOCAL_ROOT` | existing directory | unset | Root for `local://` sources; unset disables them. Must exist at boot, and may not be `/` |
| `AP_VARIANT_BUCKET` | string | unset | Write-back target; unset = always render |
| `AP_MAX_CONCURRENCY` | positive integer | schedulers online | Max simultaneous ffmpeg processes |
| `AP_QUEUE_SIZE` | non-negative integer | `32` | Waiting renders before `429` |
| `AP_MAX_SRC_BYTES` | positive integer | `2000000000` | Reject larger sources with `413` |
| `AP_RENDER_TIMEOUT` | positive integer | `300` | Seconds a render may take before ffmpeg is killed and the request answered `504`. Raise it for full-length transcodes of long masters; the default suits previews. See [docs/rendering.md](docs/rendering.md) |
| `AP_SERVE_MODE` | `redirect` \| `proxy` | `redirect` | Serve cache hits by redirect or proxied |

Booleans accept `1`/`true`/`yes`/`on` and `0`/`false`/`no`/`off`,
case-insensitively. An empty value counts as unset.

The listener port is read from `AP_PORT`, then `PORT`, then `4000`.

## Stack

Elixir with Plug and [Bandit](https://github.com/mtrudel/bandit), and no
Phoenix — there is no HTML to render and no channels to serve. ffmpeg runs as a
subprocess rather than through libav bindings, so it does all decoding and
encoding while Elixir stays orchestration; `ffprobe` backs `/info`. There is no
database, no queue and no sidecar, because the only state is what lives in S3
and in the URLs themselves. That leaves one container to deploy and nothing to
migrate.

## Documentation

| Document | What it covers |
|---|---|
| [docs/audio-proxy-api-v1.md](docs/audio-proxy-api-v1.md) | **The source of truth.** URL grammar, every processing option, cache-key rules, response headers, error codes |
| [docs/sources.md](docs/sources.md) | Source encodings and escaping, what is refused, the source-type contract and canonical identity |
| [docs/development.md](docs/development.md) | Toolchain, per-slice worktrees and devcontainers, the test suite and its tags, CI, how a release is cut |
| [VERSIONS.md](VERSIONS.md) | What the image is built from — Debian, Elixir/OTP and ffmpeg pins, why not Alpine, and how to bump one |
| [docs/ffmpeg-arguments.md](docs/ffmpeg-arguments.md) | How options become ffmpeg arguments — filter order, per-format flags, known gaps |
| [docs/rendering.md](docs/rendering.md) | How a render runs — the subprocess, the chunk stream, buffering and lifecycle guarantees |
| `openspec/specs/` | Capability specs for what is built; `openspec/changes/` holds what is planned |
