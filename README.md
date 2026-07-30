# audio_proxy

[![CI](https://github.com/audioproxy/audioproxy/actions/workflows/ci.yml/badge.svg)](https://github.com/audioproxy/audioproxy/actions/workflows/ci.yml)

An imgproxy-style on-the-fly audio transcoding proxy.

> **Status: early.** What exists today is the application skeleton — OTP app,
> supervision tree, `AudioProxy.Config`, URL signature generation/verification
> (`AudioProxy.Signature` + `AudioProxy.Plugs.VerifySignature`), the processing
> options grammar and cache-key derivation (`AudioProxy.Options` +
> `AudioProxy.CacheKey`), the ffmpeg argument builder
> (`AudioProxy.Ffmpeg.Command`), and the unsigned `GET /health` endpoint.
> Nothing runs ffmpeg yet: rendering, streaming and S3 access arrive in the
> slices tracked under `openspec/changes/`.

## Design

Sources live in S3 (or any HTTP-reachable store). Variants — transcodes, trimmed
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
headers, and error codes. Read it before touching URL parsing or response
semantics.

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

## ffmpeg arguments

`AudioProxy.Ffmpeg.Command.build/2` turns a validated options struct plus an
input URL into an argv list. It is a pure function and it is the last leg of
the round-trip: equal cache keys imply byte-identical commands, which is what
makes a cache hit a claim about bytes rather than about a URL.

```elixir
{:ok, opts} = AudioProxy.Options.parse("f:opus/br:96/t:12.5:30/fade:0.5:1")
AudioProxy.Ffmpeg.Command.build(opts, "https://masters.example/piece.wav")
# => ["-nostdin", "-hide_banner", "-loglevel", "error",
#     "-ss", "12.5", "-t", "30", "-i", "https://masters.example/piece.wav",
#     "-vn", "-af", "afade=t=in:st=0:d=0.5,afade=t=out:st=29:d=1",
#     "-c:a", "libopus", "-b:a", "96k", "-f", "ogg", "pipe:1"]
```

There is no shell anywhere in this path. The argv is a flat list of complete
arguments, so a source URL containing `;`, `$(…)` or spaces is one element and
stays data; `dl` and `cb` never reach the command at all.

### Option → ffmpeg mapping

| Option | ffmpeg | Notes |
|---|---|---|
| `t:START[:DUR]` | `-ss START [-t DUR]` **before** `-i` | Input seeking, so ffmpeg's HTTP client issues a Range request and never reads the skipped bytes. Everything downstream sees the trimmed region starting at t=0 |
| `fade:IN[:OUT]` | `afade=t=in:st=0:d=IN`, `afade=t=out:st=DUR-OUT:d=OUT` | Inside the trimmed region, by construction |
| `gain` | `volume=<dB>dB` | |
| `norm:ebu:I:TP:LRA` | `loudnorm=I=…:TP=…:LRA=…` | Single-pass (§3.2) |
| `sr` | `aresample=<Hz>` | |
| `ch` | `-ac 1` \| `-ac 2` | An output option, not a filter |
| `br` | `-b:a <kbps>k` | Lossy formats only |
| `q` | `-q:a` (mp3, ogg, aac, m4a) or `-compression_level` (opus, flac) | Whichever knob the codec has, bounded to its range |
| `bd` | `-c:a pcm_s16le`/`pcm_s24le`/`pcm_f32le` (wav), `-sample_fmt s16`/`s32` (flac) | Omitted, a lossless variant follows the source's depth |
| `f:mp3` | `-c:a libmp3lame -f mp3` | |
| `f:opus` | `-c:a libopus -f ogg` | |
| `f:ogg` | `-c:a libvorbis -f ogg` | |
| `f:aac` | `-c:a aac -f adts` | ADTS, because it streams |
| `f:m4a` | `-c:a aac -movflags empty_moov+default_base_moof -frag_duration 1000000 -f mp4` | Fragmented: plain MP4 needs a seekable output for its moov atom, and stdout is not one. Cut on duration, not `frag_keyframe` — see below |
| `f:flac` | `-c:a flac -f flac` | |
| `f:wav` | `-c:a pcm_s16le -f wav` | |
| `f:peaks` | `-c:a pcm_s16le -f s16le` | Raw PCM for the peak reducer, not an encode |

Every command writes to `pipe:1` behind an explicit `-f`, since stdout has no
filename for ffmpeg to infer a muxer from, and every command runs with
`-nostdin -hide_banner -loglevel error` so stderr carries diagnostics only.

### Why `m4a` fragments on duration

`-movflags frag_keyframe` starts a new fragment at each video keyframe. An
audio-only stream has none, so `empty_moov` alone produces exactly **one**
fragment, which ffmpeg flushes when the input ends — a valid file on a
non-seekable pipe, but not a stream. Measured on a 20 s source fed at realtime:

| movflags | first bytes | fragments | size |
|---|---|---|---|
| `frag_keyframe+empty_moov` | 19.7 s | 1 | 328218 |
| `empty_moov+default_base_moof` + `-frag_duration 1000000` | 1.8 s | 20 | 327275 |
| `empty_moov+frag_every_frame` | 0.2 s | 863 | 437684 |
| mp3, for reference | 0.2 s | — | — |

One-second fragments cost nothing measurable in size and make the stream a
stream, so that is what the builder emits. The `:ffmpeg`-tagged suite counts
the fragments and measures time-to-first-byte, so the regression cannot come
back quietly.

Filters run in the order `loudnorm → volume → aresample → afade`, and the
order is load-bearing. `loudnorm` goes first because normalizing after a
static `gain` would undo it; `aresample` follows it because single-pass
`loudnorm` resamples its output to 192 kHz; `afade` goes last so the fade
shape survives the stages above it.

That 192 kHz has one visible consequence: **`norm` without an explicit `sr`
appends `aresample=48000`.** Without it every normalized render would be a
192 kHz file. 48 kHz is the API's own lossy ceiling (§3.1) and universally
supported, but it does mean `norm` on a 96 kHz lossless master downsamples.
Choosing better would need the source's real sample rate, which the argument
builder deliberately does not know — it is a pure function of the options, and
that purity is what the round-trip property rests on. Pass `sr` explicitly to
override.

### ffmpeg version

The argv is a contract with a specific ffmpeg, not with "ffmpeg" in the
abstract: encoder names, muxer names and filter option spellings all drift
between versions. The devcontainer and the release image therefore install
ffmpeg from the same distro packaging, and the `:ffmpeg`-tagged tests
(`test/audio_proxy/ffmpeg/command_ffmpeg_test.exs`) run every format and every
filter through the real binary, so a codec name that a build does not carry
fails a test rather than a request. Pinning an exact ffmpeg version — and
whether to build it from source with a trimmed codec set — is decided in
`add-docker-release`.

Two known gaps. libopus encodes at 48/24/16/12/8 kHz only, so `sr:44100` with
`f:opus` is resampled to 48 kHz by ffmpeg's own negotiation and produces the
same bytes as `f:opus` alone, under a different cache key. And with no `bd`,
`f:wav` falls back to 16-bit whenever the source's depth is unknown — the
builder takes it as an argument (`build/3`), but the probe that supplies it
belongs to the `/info` slice, so until then a 24-bit master requested as
`f:wav` comes back 16-bit unless `bd:24` is given. Both cost a duplicate cache
object or a documented fallback, not a wrong render, and both are tracked with
the semantic no-ops above.

## Stack

- **Elixir** with Plug + [Bandit](https://github.com/mtrudel/bandit) — no
  Phoenix, since there is no HTML and no channels to serve.
- **ffmpeg as a subprocess**, not libav bindings. ffmpeg does all
  decoding/encoding; Elixir is orchestration only. `ffprobe` backs `/info`.
- **No database, no queue, no sidecar.** State lives in S3 and in URLs.

## Toolchain

Elixir and Erlang/OTP are pinned as a matched pair in
[`.tool-versions`](.tool-versions); bump them together. That file is the single
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

## Getting started

```bash
mix deps.get
mix test
PORT=4000 mix run --no-halt
curl -s localhost:4000/health
# {"status":"ok","version":"0.1.0"}
```

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
| `AP_SOURCE_ALLOWLIST` | comma-separated | empty | Permitted source buckets/hosts |
| `AP_VARIANT_BUCKET` | string | unset | Write-back target; unset = always render |
| `AP_MAX_CONCURRENCY` | positive integer | schedulers online | Max simultaneous ffmpeg processes |
| `AP_QUEUE_SIZE` | non-negative integer | `32` | Waiting renders before `429` |
| `AP_MAX_SRC_BYTES` | positive integer | `2000000000` | Reject larger sources with `413` |
| `AP_RENDER_TIMEOUT` | positive integer | `300` | Seconds before a render is killed (`504`) |
| `AP_SERVE_MODE` | `redirect` \| `proxy` | `redirect` | Serve cache hits by redirect or proxied |

Booleans accept `1`/`true`/`yes`/`on` and `0`/`false`/`no`/`off`,
case-insensitively. An empty value counts as unset.

The listener port is read from `AP_PORT`, then `PORT`, then `4000`.

## Tests

```bash
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

[`.github/workflows/ci.yml`](.github/workflows/ci.yml) runs on every push to
`main` and every pull request, in two jobs:

| Job | Runs | Notes |
|---|---|---|
| `test` | `mix format --check-formatted`, `mix compile --warnings-as-errors`, `mix test --include integration` | No external binaries — the untagged + `:integration` suite must pass on a bare runner |
| `test-ffmpeg` | `mix test --only ffmpeg` | Installs ffmpeg first; renders every format and filter through the real binary |

Compilation runs with warnings as errors because the compiler's set-theoretic
type checker reports through warnings — that flag is what makes the type gate a
gate rather than a suggestion.

Both jobs read Elixir and Erlang/OTP from [`.tool-versions`](.tool-versions),
so bumping the pin is a one-file change that CI follows automatically. The
`deps`/`_build` cache is keyed on the resolved versions plus `mix.lock`, so a
toolchain bump misses the cache rather than restoring BEAM files built by a
different compiler.

Later slices extend this workflow rather than adding parallel ones — the image
build and smoke tests from `add-docker-release`, and MinIO as a service
container from `add-s3-client` — so there stays exactly one check to require.

[`.github/dependabot.yml`](.github/dependabot.yml) opens update PRs weekly for
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

## Development workflow

Everything below is about *how* work happens here, not about the proxy itself.

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
the hooks in [`.config/wt.toml`](.config/wt.toml).

The devcontainer image
([`.devcontainer/Dockerfile`](.devcontainer/Dockerfile)) pins the same
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
