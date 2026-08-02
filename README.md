# audio_proxy

[![CI](https://github.com/audioproxy/audioproxy/actions/workflows/ci.yml/badge.svg)](https://github.com/audioproxy/audioproxy/actions/workflows/ci.yml)

Transcode audio on demand, from a URL.

Point it at your audio and ask for a variant by URL: a 30-second preview, a mono file for speech-to-text, a normalised podcast MP3, a 24-bit FLAC excerpt. The options are in the path, so one master can serve all of them and you generate none of them in advance. If you know [imgproxy](https://imgproxy.net), this is that, for audio.

> **Status: early, `v0.1.0`.** Transcoding works end to end from a mounted directory and you can try it in about a minute. Do not put it in front of production traffic yet: nothing is kept once a render finishes, so a variant is encoded again for every request that does not overlap another, and nothing bounds how many renders run at once. See the [Roadmap](#roadmap).

## Quick start

Point it at a directory of audio you already have. No signing key, no bucket, no config file.

```bash
docker run --rm -p 4000:4000 \
  -e AP_ALLOW_INSECURE=true \
  -e AP_LOCAL_ROOT=/audio \
  -v /path/to/your/audio:/audio:ro \
  ghcr.io/audioproxy/audioproxy:0.1.0
```

> On Apple Silicon, add `--platform linux/amd64`. The image is x86-64 only for now and runs under emulation; arm64 is [its own slice](openspec/changes/add-multi-arch-images).

Now ask for a variant, from another shell. `SRC` names a file *relative to the directory you mounted*, so `track.wav` means `/path/to/your/audio/track.wav`:

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

Both start arriving while ffmpeg is still encoding: the response is chunked, not buffered to disk first. Change any option and you have a different variant, with no server-side configuration to add: the URL is the whole request.

To hear it rather than download it, save this as `player.html` and open it in a browser:

```html
<audio controls src="http://localhost:4000/insecure/f:mp3/br:128/plain/local://track.wav"></audio>
```

Playback starts before the render finishes, which is the point. `f:mp3` because every browser plays it; Safari will not play Ogg or Opus. For something to poke at rather than a single tag, [`examples/player.html`](examples/player.html) has presets for every format and shows what the browser makes of the response.

**While it renders, the duration reads as unknown and you cannot seek**, because a render in progress has no length and nothing to seek into: it is delivered chunked, with no `Content-Length` and no `Accept-Ranges`. Once the whole thing has arrived the browser can scrub within what it holds, so on a short file this is barely visible. What you cannot do, at any point, is jump to a position that has not been received — without `Accept-Ranges` the browser has to fetch everything up to that point first, which on a long file is the difference between seeking and waiting. Range requests need a *cached* variant with a known size; see the [Roadmap](#roadmap).

Two things that matter beyond a first try:

- **`AP_ALLOW_INSECURE` is development only.** It is what lets the literal `insecure` stand in for a signature, so while it is on, anyone who can reach the port can render anything under `AP_LOCAL_ROOT`. [Signing URLs](#signing-urls) is the real thing.
- **Mount the directory read-only** (`:ro`, above). Write access to `AP_LOCAL_ROOT` is write access to what the proxy will serve.

[Running it](#running-it) has the shape you would actually deploy.

## What you can do with it

The path is `/{signature}/{options}/{source}`. These examples show the range, using the literal `insecure` in place of a signature as the Quick start did.

```bash
BASE=localhost:4000
SRC='plain/local://piece.wav'    # AP_LOCAL_ROOT/piece.wav
# A 30-second preview: Opus at 96 kbps, starting 12.5 s in,
# half-second fade in and one-second fade out.
curl "$BASE/insecure/f:opus/br:96/t:12.5:30/fade:0.5:1/$SRC"

# Waveform peaks to draw a player UI, 800 min/max pairs as JSON.
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

Each URL describes its output completely, so the same URL always means the same bytes. The first request for a variant renders it and streams it while it encodes; later requests are served from the variant bucket with `Range` support.

> **Which of these work today?** The first six return audio. `f:peaks` and `info` do not yet; see the [Roadmap](#roadmap). Every option string above is checked against the parser by the test suite, so none of them are aspirational spellings.

## Roadmap

No dates. It is built in small releases, each one usable, in roughly this order.

**Working now (`v0.1.0`)**

- Signed URLs, the full processing-options grammar, and the cache-key rules
- Transcoding to MP3, AAC/M4A, Opus, Vorbis, FLAC and WAV, with trimming, fades, loudness normalisation, channel and sample-rate control
- Renders stream while they encode, from files in a mounted directory
- Concurrent requests for the same variant share one render, with mid-render joiners catching up from the start
- A single container, published per release

**Next: what makes it production-shaped**

- **A variant cache.** Requests that overlap already share a render, but nothing survives it, so the next one encodes the variant again. Rendered variants will be written back to a store and served from there on later requests, with `Range` support and byte-serving. Where they are stored is a separate choice from where sources come from: a local directory for a single node, object storage when you have more than one.
- **Bounded concurrency.** A cap on simultaneous renders with a wait queue, so a burst of traffic queues instead of thrashing the machine.
- **S3 sources**, so the audio itself can live in object storage.

**After that**

- `GET /info`, giving duration, sample rate and channels, so clients can build sensible variant URLs
- `f:peaks`, waveform min/max data for drawing player UIs without decoding audio in the browser
- HTTPS sources, for stores that are not S3
- A Prometheus `/metrics` endpoint reporting queue depth, render durations and hit ratio
- arm64 images, so Graviton/Ampere and Apple Silicon run natively

**Under consideration**

- **Seeking on a first play.** The cache makes every request after the first one range-capable; the first still streams, so it can only be scrubbed within what has already arrived. A `/sync/{signature}/{options}/{source}` URL would render fully before responding and hand back something seekable — trading time-to-first-byte for a working scrubber, and chosen by whoever writes the `src` rather than by the browser. That last point is what makes it possible at all: a browser cannot signal the intent itself, since it sends `Range: bytes=0-` on *every* first media request, so keying off `Range` would make all playback wait for a full render.

  Whether it gets built is still open, because warming the cache does the same job for nothing: fetch the URL once, discard it, then set `src`, and the second request seeks normally.

**Deliberately not planned**

- **Video.** This is an audio proxy and will refuse video input rather than become a general ffmpeg gateway; video transcoding is far more expensive and carries most of ffmpeg's CVE history.

**Wanted, but not designed yet**

- **HLS and segmented streaming.** A v2 goal rather than a rejected one: the URL space is reserved, and segmented output is the honest answer to mid-stream render failure, which plain chunked HTTP cannot signal. A segment is close to a variant with a trim, so signing, cache keys and deduplication carry over unchanged. The unsolved part is gapless boundaries, since encoding each segment independently gives each one its own encoder priming.

`0.x` means the URL contract can still change. It will settle at `1.0`, after which a change to what an existing URL means, or to how cache keys are derived, is a major version. The per-slice detail, including rationale and trade-offs, lives in [`openspec/changes/`](openspec/changes).

## Design

Sources live on a mounted directory, in S3, or in any HTTP-reachable store. Variants (transcodes, trimmed previews, waveform peaks) are rendered on demand by ffmpeg, streamed to the first requester as they encode, and teed to a variant bucket, so later requests for the same variant redirect to object storage and get `Range` support and byte-serving for free.

URLs are the entire API: no request bodies, no server-side state. Every variant is fully described by its processing options, which double as its cache key, and every URL is signed.

```
GET /{signature}/{options}/{source}
```

That is the design. The [Roadmap](#roadmap) says which parts of it exist today.

**[`docs/audio-proxy-api-v1.md`](docs/audio-proxy-api-v1.md) is the source of truth** for the URL grammar, processing options, cache-key rules, response headers, and error codes. What follows here is the working subset; reach for the spec when you need the exact contract.

## Running it

The container is the way to run this. It carries the release with its own Erlang runtime and the ffmpeg the renders are tested against, so there is nothing to install and nothing to keep in step.

The [Quick start](#quick-start) above runs it unsigned, for a first look. The difference in a real deployment is that `AP_ALLOW_INSECURE` is gone and a key and salt take its place:

```bash
docker run --rm -p 4000:4000 \
  -e AP_KEY="$AP_KEY" -e AP_SALT="$AP_SALT" \
  -e AP_LOCAL_ROOT=/audio \
  -v /path/to/your/audio:/audio:ro \
  ghcr.io/audioproxy/audioproxy:0.1.0
```

That is the whole configuration for serving files off a mounted directory: no credentials, no bucket, no database.

**Pin a version.** `:0.1.0` and `:sha-<commit>` name an exact image; `:0.1` follows patch releases; `:latest` and `:edge` move under you, and `:edge` is whatever last landed on `main`. Pinning matters more here than for most services, because a different ffmpeg encodes the same URL to different bytes, which is also why a pin bump always cuts a release. The pinned versions are in [VERSIONS.md](VERSIONS.md).

To run it from a checkout instead, for development or to build your own image:

```bash
mise install          # Elixir and Erlang/OTP, pinned in .tool-versions
mix deps.get
PORT=4000 mix run --no-halt
```

That path needs `ffmpeg` and `ffprobe` on `PATH`. For a development container that already has them, and for the test suite, see [docs/development.md](docs/development.md).

## Signing URLs

Every URL is signed: the first path segment is `base64url(HMAC-SHA256(key, salt ‖ rest-of-path))`, computed over the exact bytes after the signature segment, leading `/` included, taken from the raw (still percent-encoded) request path. Key and salt are the hex-decoded values of `AP_KEY`/`AP_SALT`. Signatures are emitted unpadded; the canonical padded form is accepted on verification, but non-canonical spellings (over-padding, variant final characters) are rejected, so a signature cannot be respelled.

`AudioProxy.Signature.sign/3` is the reference signer:

```elixir
key  = Base.decode16!("00112233445566778899AABBCCDDEEFF00112233445566778899AABBCCDDEEFF")  # AP_KEY
salt = Base.decode16!("FFEEDDCCBBAA99887766554433221100")  # AP_SALT
rest = "/f:opus/br:96/plain/s3://masters/2026/piece-final.wav"

AudioProxy.Signature.sign(rest, key, salt)
# => "zfLTfPPhQ8kdeYYJOdagqPfog2nFk7KzDFUjtRAf_Ns"
```

→ the URL is `/<signature><rest>`, i.e. `/zfLTfPPhQ8kdeYYJOdagqPfog2nFk7KzDFUjtRAf_Ns/f:opus/br:96/plain/s3://masters/2026/piece-final.wav`.

Sign the URL-escaped path exactly as it will be requested. Verification runs over the raw request path, so re-encoding anything breaks the signature: a key with a space must appear as `a%20track.wav` in both the signature input and the request (or use the `enc/` source form, which exists precisely to avoid escaping headaches). For non-Elixir clients, the same three lines in Ruby:

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

Generate a real key with `openssl rand -hex 32`. `AP_KEY` must decode to at least 32 bytes or the proxy refuses to boot. **The key above is a published test vector** used throughout the test suite; never use it as a real key.

> **Dev mode, never enable in production.** Setting `AP_ALLOW_INSECURE=true` makes the literal segment `insecure` pass as a signature (`/insecure/f:opus/…/plain/…`). It exists for local development and smoke tests; with it on, anyone who can reach the proxy can render anything.

## Rendering a variant

End to end, with a directory of your own audio and a real signature:

```bash
export AP_KEY=$(openssl rand -hex 32)
export AP_SALT=$(openssl rand -hex 16)
export AP_LOCAL_ROOT=/path/to/your/audio
PORT=4000 mix run --no-halt &
```

Sign the path (everything after the signature segment, leading `/` included) and request it:

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
cache-control: public, max-age=31536000, immutable, no-transform
etag: "6f1c…"
x-audio-proxy: MISS
```

The first bytes leave before ffmpeg has finished, so a long transcode starts playing immediately rather than after it completes. There is no `Content-Length` and no `Accept-Ranges` on this response: the length is not known when the head goes out, and ranges arrive with the variant cache, whose `HIT` redirects to storage that serves them natively.

`x-audio-proxy` says where the bytes came from. `MISS` is this request's own render. `COALESCED` means another request was already rendering exactly this variant and this one attached to it: the same bytes, no second ffmpeg. `HIT` arrives with the variant cache, which does not exist yet, so today every response is one of the first two. `etag` is the variant's cache key, which is a pure function of the normalized options and the source, so the same variant requested with its options in a different order carries the same one.

Requests for the same variant share a render, so a burst — a page that loads the same preview for fifty visitors at once — costs one encode rather than fifty. A request arriving mid-render is sent everything encoded so far, then the rest as it comes, so it gets the whole file and not the tail. A shared render is held in memory for as long as it runs, and output past `AP_MAX_SRC_BYTES` fails rather than growing without limit — so that variable bounds variant size as well as source size.

If the client goes away mid-stream, the render goes with it, unless someone else is still listening to the same one: closing the last connection kills the ffmpeg process rather than leaving it encoding into a socket nobody is reading. A render that fails *before* any bytes are sent is one of the JSON errors below; one that fails after them can only be signalled by cutting the connection short, so treat a chunked response that ends without its terminating chunk as a failed download.

For what happens behind that (the subprocess, coalescing, buffering, the timeout and the kill discipline) see [docs/rendering.md](docs/rendering.md).

## Caching and CDNs

The proxy is built to sit behind a CDN without special configuration on either side: the URL names the variant completely, the `ETag` is the cache key, there are no cookies and no `Vary`, and changing `cb` busts every tier at once. Every response states how long it may be held, so no CDN negative-caching default — where Cloudflare, CloudFront, and Fastly differ most — ever decides retention:

| Response | `Cache-Control` | Why |
|---|---|---|
| `200` media / peaks | `public, max-age=31536000, immutable, no-transform` | The URL encodes the variant, so it *is* immutable; `no-transform` keeps edge features from recompressing or mangling the bytes |
| `404` | `max-age=10` | Sources appear — a file uploaded moments after the miss is served within seconds |
| `413`, `415` | `max-age=10` | Verdicts about the current source bytes, which a re-upload changes |
| `401`, `422` | `max-age=60` | Pure functions of the URL: a bad signature never becomes good, invalid options never become valid — only a deploy changes that |
| `429`, `500`, `504` | `no-store` | Transient — caching a transient failure amplifies it (`429` carries `Retry-After`) |
| `/health` | `no-store` | Liveness is only worth anything fresh |

Three behaviors round out the CDN-facing surface:

- **Revalidation costs no render.** A request whose `If-None-Match` matches the variant's `ETag` answers `304` before the proxy touches storage or spawns anything — the ETag derives from the URL alone. The signature still gates: an unsigned request is `401`, matching validator or not.
- **HEAD works.** `HEAD` on a signed URL answers the status and headers a `GET` would, through every check including the source stat, with an empty body and no render. Errors answer as `GET` does, bodiless. `HEAD /health` works too.
- **`Range` on an uncached variant is ignored.** A `Range` header on a variant that has to be rendered gets the full `200` chunked stream (RFC 9110 permits this), with no `Accept-Ranges` and no `206`. Range serving belongs to cached variants: once the variant cache lands, a `HIT` redirects to storage, which serves `206` natively — that discipline arrives with that slice.

## Processing options

The options segments describe the variant completely, and their normalized form *is* the cache key. `AudioProxy.Options` parses, validates, and normalizes them; `AudioProxy.CacheKey` hashes the result. Invalid or conflicting options are rejected with an `AudioProxy.OptionError` naming the offending segment, which the HTTP layer will render as a `422`.

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
| `norm` | `ebu[:I[:TP[:LRA]]]` | Loudness normalization; targets default to `-16:-1.5:11`. v1 runs `loudnorm` single-pass, good enough for previews but not for masters (§3.2) |
| `pts` | positive integer | Peaks: number of min/max pairs; default `800` |
| `pk_fmt` | `json` \| `dat` | Peaks: output encoding; default `json` |
| `dl` | filename | Sets `Content-Disposition: attachment` |
| `cb` | opaque string | Cache-buster; participates in the cache key |

Decimals are accepted to three places (millisecond precision) and rejected beyond that rather than silently rounded, so float formatting can never destabilize a cache key. `-0` is collapsed to `0` at parse time: it renders as `0`, so it cannot be told apart in a cache key, and letting it into the struct would let it be told apart in the ffmpeg arguments. `dl` and `cb` values stay percent-encoded and are treated as opaque bytes.

### Validation rules

Beyond each key's own value domain, these cross-key rules are enforced:

- `br` and `q` are mutually exclusive.
- `br` requires a lossy format; `q` requires a format whose encoder has a quality scale (everything but `wav`).
- `bd` requires a lossless format (`flac`, `wav`), and `bd:32f` requires `f:wav`, since flac encodes integer samples only.
- `q` must sit inside its codec's scale: mp3 0–9, ogg −1–10, aac/m4a 0.1–2, opus 0–10, flac 0–12. `f:flac/q:13` is refused by ffmpeg itself ("invalid compression level"), so refusing it here turns a 500 into a 422.
- `pts` and `pk_fmt` require `f:peaks`.
- `sr` is capped at 48 kHz for lossy formats.
- A fade must fit inside the trimmed region when the trim is bounded, and a fade-out requires a bounded trim at all: its start is `duration - out`, and without a duration there is nothing to count back from. A fade-in needs no trim, since it starts at zero.

Peaks add one more: `f:peaks` refuses `br`, `q`, `sr`, `bd`, `gain` and `norm`. Peaks are computed from the decoded source and respect only `t`, `ch` and `fade` (§3.3), so accepting an option that cannot change the output would hand byte-identical peaks two different cache keys. `f:peaks/br:96` is a 422.

The rules about `br`, `q` and `bd:32f` come from the same principle applied one layer down: ffmpeg accepts `-b:a` on a flac encode and ignores it, so `f:flac/br:320` would be two cache keys for one file. Rejecting is cheaper than storing the duplicate.

Unknown keys, repeated keys, empty segments, and valueless segments are rejected too. There is no last-write-wins and no silent ignoring, because either would let two different URLs mean the same variant. Values are also bounded above (`br` ≤ 10000, `sr` ≤ 384000, `pts` ≤ 100000, `|gain|` ≤ 100) so a mistyped URL fails here as a 422 rather than downstream as a render error, and `dl`/`cb` reject control characters. That last rule is what makes the cache key's separator sound (see below).

### Cache-key semantics

```
lowercase-hex(SHA-256(normalized-options ‖ "\n" ‖ canonical-source))
```

Normalization is what makes this deterministic: keys are sorted lexicographically, applicable defaults are materialized (`f`, the `norm` targets when `norm` is present, `pts`/`pk_fmt` under `f:peaks`), and every number is rendered minimally (`30`, never `30.0`). So `f:opus/br:96` and `br:96/f:opus` are one variant with one key, while any genuine difference, `cb` included, yields a different one. The `"\n"` is load-bearing: without it, `("", "/gain:3")` and `("gain:3", "")` would hash identical bytes, which is why control characters are refused in the only two options whose values are opaque.

Normalization is syntactic, not semantic: `t:0`, `fade:0:0` and `gain:0` are identity renders but keep their own keys, so those spellings cost duplicate cache objects. Collapsing them is tracked as follow-up work. The property suite (`test/audio_proxy/options_property_test.exs`) holds this line: normalization is idempotent, order-insensitive, and always re-parses.

## Sources

The last portion of the path names what to render, in one of two forms:

| Form | Example |
|---|---|
| `plain/{source}` | `plain/s3://masters/2026/piece-final.wav` |
| `enc/{base64url(source)}` | `enc/czM6Ly9tYXN0ZXJzLzIwMjYvcGllY2UtZmluYWwud2F2` |

Both name the same thing and produce the same cache key. `enc/` exists because escaping a URL inside a URL is easy to get wrong: base64url the source as written and you are done.

In the `plain/` form the source is percent-escaped, and it is unescaped exactly once. A space is `%20`, a literal percent is `%25`, and `+` is a literal plus. One consequence to watch: a source that already carries escapes has to be escaped *again*, so a URL ending in `a%20b.wav` is written `plain/https://h/a%2520b.wav`. Sign the source in the same spelling you request it in, because the signature covers the raw path.

### `local://`: files under a configured root

`local://{path}` serves a path relative to `AP_LOCAL_ROOT`. Mount the directory you want served, read-only, and point the proxy at it:

```bash
docker run -p 4000:4000 \
  -e AP_ALLOW_INSECURE=true \
  -e AP_LOCAL_ROOT=/srv/audio \
  -v /path/to/your/audio:/srv/audio:ro \
  ghcr.io/audioproxy/audioproxy:0.1.0

# …renders /srv/audio/previews/track.wav
curl "$BASE/insecure/f:mp3/br:128/plain/local://previews/track.wav"
```

Unset `AP_LOCAL_ROOT` and local sources are refused outright: the root is the whole access-control story for disk. **Mount it read-only.** Write access to the root is equivalent to choosing what the proxy will serve.

[docs/sources.md](docs/sources.md#local-sources) has the confinement rules, the path limits, and why the root never appears in a cache key.

**`s3://` and `https://` sources are not built yet**. Each is its own slice, with its own rule for what it will serve, and until they land those schemes are refused as unknown. See [docs/sources.md](docs/sources.md) for the contract they plug into and `openspec/changes/` for which slice adds which.

## Errors

Failures are JSON, one shape everywhere: `{"error": "…", "message": "…"}`.

| Status | `error` | When |
|---|---|---|
| `401` | `invalid_signature` | Missing or invalid signature |
| `404` | `not_found` | The source is missing, unreadable, unparseable, or not one this proxy may serve, deliberately indistinguishable, so a `404` tells you nothing about what exists on disk |
| `413` | `source_too_large` | The source exceeds `AP_MAX_SRC_BYTES` |
| `415` | `undecodable_source` | The source format is not decodable |
| `422` | `invalid_options` | Invalid or conflicting options; the message names the offending segment |
| `429` | `queue_full` | The render queue is full; `Retry-After` is set |
| `500` | `render_failed` | The render failed for a reason that is not yours: no encoder on the host, no disk space, a failure the proxy could not classify. Worth retrying |
| `504` | `render_timeout` | The render exceeded `AP_RENDER_TIMEOUT` |

All of these are reachable except `429`, which arrives with the render queue (`openspec/changes/add-render-semaphore`). A failure *after* the response has begun is not in this table and cannot be: see [Rendering a variant](#rendering-a-variant).

## Configuration

All configuration comes from `AP_`-prefixed environment variables. See `docs/audio-proxy-api-v1.md` §6 for intent and `AudioProxy.Config` for parsing. Values are read, typed, and validated once at boot; a malformed value aborts startup with an error naming the variable.

Note that the variables below are the full configuration surface for the design, so several of them are parsed and validated but not yet consumed by anything.

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
| `AP_MAX_SRC_BYTES` | positive integer | `2000000000` | Reject larger sources with `413`; also caps the bytes a render may hold in memory |
| `AP_RENDER_TIMEOUT` | positive integer | `300` | Seconds a render may take before ffmpeg is killed and the request answered `504`. Raise it for full-length transcodes of long masters; the default suits previews. See [docs/rendering.md](docs/rendering.md) |
| `AP_SERVE_MODE` | `redirect` \| `proxy` | `redirect` | Serve cache hits by redirect or proxied |
| `AP_LOG_LEVEL` | `debug` \| `info` \| `warning` \| `error` | `info` | Lowest level written to stdout. See [Logs](#logs) |

Booleans accept `1`/`true`/`yes`/`on` and `0`/`false`/`no`/`off`, case-insensitively. An empty value counts as unset.

The listener port is read from `AP_PORT`, then `PORT`, then `4000`.

## Logs

Everything goes to stdout, one line per completed request:

```
12:31:07.442 request_id=GMf5ECU8WG_tDMEAAAJC [info] render 200 opts=br:96/f:opus src=local://piece.wav cache=MISS 27141 bytes in 63.4ms
12:31:07.981 request_id=GMf5ECU9xK2sPQ1AAAJD [info] render 200 opts=br:96/f:opus src=local://piece.wav cache=COALESCED 27141 bytes in 2.8ms
12:31:09.118 request_id=GMf5EGolMMyBOD4AAA7B [info] render 422 invalid_options 74 bytes in 0.3ms
12:31:11.006 request_id=GMf5ECRh8raItPUAAAOl [warning] render 504 render_timeout opts=f:mp3 src=local://long.wav cache=MISS 72 bytes in 300004.7ms
```

Reading one left to right: the endpoint (`render`, `health`, or `unknown` for a path that matched no route), the status, the error code from the [Errors](#errors) table when the request failed, the normalized options string and the canonical source once the proxy has got far enough to know them (a `401` knows neither and omits both), whether the request rendered or shared one, the bytes sent, and how long it took.

`cache=` is the field to read before drawing conclusions from a duration. The second line above delivered the same 27 kB as the first in a fortieth of the time because it attached to the render already running for that variant — not because ffmpeg was fast.

`request_id` is on every line, and the same id comes back to the client in the `x-request-id` response header — so a report of "this URL was slow at 12:31" can be traced to the render behind it. Send your own `x-request-id` and it is used instead, which is what makes the log line up with a proxy or gateway in front.

Levels:

| Level | What appears |
|---|---|
| `error` | Nothing routine: a render the host could not start at all (no encoder on `PATH`), a subprocess that survived `SIGKILL`, and crashes |
| `warning` | `5xx` and `504` responses, and the ffmpeg diagnostic behind a failed render |
| `info` | **Default.** The above, plus one line per request, `4xx` included: a `401` is a normal outcome for a public endpoint, not an incident |
| `debug` | The above, plus `/health` (silent otherwise, so a liveness probe every second does not become the log), the render lifecycle, and client disconnects |

Set the floor with `AP_LOG_LEVEL`; `warning` is the setting for a busy production instance that wants failures only.

Presigned URLs and credentials never appear. Sources are logged by their canonical identity (`local://piece.wav`), never by what ffmpeg was handed to read, and diagnostics quoted back from ffmpeg have their query strings stripped.

Structured JSON output is not implemented yet — it arrives with its own slice.

## Stack

Elixir with Plug and [Bandit](https://github.com/mtrudel/bandit), and no Phoenix, because there is no HTML to render and no channels to serve. ffmpeg runs as a subprocess rather than through libav bindings, so it does all decoding and encoding while Elixir stays orchestration; `ffprobe` backs `/info`. There is no database, no queue and no sidecar, because the only state is what lives in S3 and in the URLs themselves. That leaves one container to deploy and nothing to migrate.

## Documentation

| Document | What it covers |
|---|---|
| [docs/audio-proxy-api-v1.md](docs/audio-proxy-api-v1.md) | **The source of truth.** URL grammar, every processing option, cache-key rules, response headers, error codes |
| [docs/sources.md](docs/sources.md) | Source encodings and escaping, what is refused, the source-type contract and canonical identity |
| [docs/development.md](docs/development.md) | Toolchain, per-slice worktrees and devcontainers, the test suite and its tags, CI, how a release is cut |
| [examples/](examples) | A one-file browser player for trying variants, and why it has to be served rather than opened |
| [VERSIONS.md](VERSIONS.md) | What the image is built from: Debian, Elixir/OTP and ffmpeg pins, why not Alpine, and how to bump one |
| [docs/ffmpeg-arguments.md](docs/ffmpeg-arguments.md) | How options become ffmpeg arguments: filter order, per-format flags, known gaps |
| [docs/rendering.md](docs/rendering.md) | How a render runs: the subprocess, the chunk stream, coalescing, buffering and lifecycle guarantees |
| `openspec/specs/` | Capability specs for what is built; `openspec/changes/` holds what is planned |
