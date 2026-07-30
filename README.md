# audio_proxy

[![CI](https://github.com/audioproxy/audioproxy/actions/workflows/ci.yml/badge.svg)](https://github.com/audioproxy/audioproxy/actions/workflows/ci.yml)

An imgproxy-style on-the-fly audio transcoding proxy.

> **Status: early.** What exists today is the application skeleton — OTP app,
> supervision tree, `AudioProxy.Config`, URL signature generation/verification
> (`AudioProxy.Signature` + `AudioProxy.Plugs.VerifySignature`), and the
> unsigned `GET /health` endpoint. Rendering and S3 access arrive in the
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
default. Run them explicitly, on a machine that has ffmpeg installed:

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
| `test-ffmpeg` | `mix test --only ffmpeg` | Installs ffmpeg first; no-ops green until the first `:ffmpeg`-tagged test exists |

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
