# Development

How work happens in this repository: the pinned toolchain, the per-slice
worktree workflow, the test suite and its tags, and the CI gate. None of it is
needed to run the proxy — see the [README](../README.md) for that.

## Toolchain

Elixir and Erlang/OTP are pinned as a matched pair in
[`.tool-versions`](../.tool-versions); bump them together. That file is the single
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

## Running the suite

```bash
mix deps.get
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

Tests tagged `:integration` bind a real socket to verify adapter behavior end
to end — that the signed request path reaches the verifier byte-identical to
what the client sent, and that the streaming lifecycle (chunk framing, client
disconnect, a stream torn down after its `200`) behaves on the wire. They are
excluded by default but run in CI; locally:

```bash
mix test --include integration
```

Tests tagged `:minio` need a real S3-compatible store. `AudioProxy.S3` is a
thin layer over `ex_aws_s3`, so what is worth testing is *our* half — the
config overrides, the addressing decision, the error translation, the
metadata round trip, the single-`PutObject` fast path and the part grouping
`ex_aws` does not do. A stub would agree with us about all of it; a store
does not.

In the devcontainer MinIO is already running as a compose service at
`minio:9000`, so this just works:

```bash
mix test --only minio
```

Anywhere else, point the suite at a store you started yourself:

```bash
docker run -d --name minio -p 9000:9000 \
  -e MINIO_ROOT_USER=minioadmin -e MINIO_ROOT_PASSWORD=minioadmin \
  minio/minio:RELEASE.2025-04-22T22-12-26Z server /data

AP_TEST_MINIO_ENDPOINT=http://127.0.0.1:9000 mix test --only minio
```

Credentials are fixed at `minioadmin`/`minioadmin` and the bucket
(`audio-proxy-test`) is created by the suite. It **fails rather than skips**
when MinIO is unreachable: these tests are excluded by default, so anything
that asked for them wants them run, and a green run against nothing is a lie
about coverage.

**No two of the three tags go on the same test.** They are exclusion filters, and
including one overrides the others' exclusion, so a test carrying two would be
dragged into a job that cannot satisfy it — the `test` CI job has no ffmpeg,
and `--only minio` on a laptop has no store. A socket-binding test that
also needs the real encoder is therefore tagged `:ffmpeg` only —
`AudioProxy.RenderEndpointFfmpegTest` is the one that does. Everything else
about the streaming path runs against a stand-in encoder
(`test/support/fake_ffmpeg.sh`), which is what makes a hang, a dribble or a
mid-stream failure reproducible on demand.

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

## The container smoke suite

`mix test` says nothing about the artifact that ships. [`bin/smoke-image`](../bin/smoke-image)
builds the release image and drives it from outside, the way an operator would:

```bash
bin/smoke-image                 # build, then run every check
SKIP_BUILD=1 bin/smoke-image    # reuse an already-built audio_proxy:smoke
```

It needs docker and curl, and deliberately not ffmpeg — the fixtures are
generated with the image's own ffmpeg and the durations read back with its
ffprobe, so what it measures is the shipped binary rather than yours. It checks
that the release boots non-root and reaches `/health`, that a signed URL
carrying a percent-escape renders over **h2c** (Bandit builds `request_path`
separately on its HTTP/2 path, so the `:integration` suite's HTTP/1.1 guarantee
does not carry over), that a malformed `AP_` variable kills the container, and
that SIGTERM during a render is a prompt clean exit with ffmpeg gone from the
process table first.

The fixture directory is mounted `:ro` throughout, which is the posture the
README tells operators to use rather than an incidental detail — write access to
`AP_LOCAL_ROOT` is write access to what the proxy will serve.

It also renders an **`s3://` source**, against a MinIO container on a
suite-private network: the fixture is uploaded with `mc`, the proxy signs its
own presigned URL, and the shipped ffmpeg opens that URL and ranges it over the
network. Then the store is removed and a source that is plainly there answers
`502` rather than `404`. Both are here rather than only in the `:minio` ExUnit
suite for the reason [Releases](#releases) gives: v0.3.0's notes announced S3
rendering that no check exercised, and a release gate that cannot see S3 cannot
catch that.

The **`s3://` variant store** gets the same treatment, and one assertion no unit
suite can make: a render is teed into a MinIO bucket, the same URL comes back as
a `HIT` with a declared length and `Accept-Ranges`, and then the container that
rendered it is *removed* and a second one — in `redirect` mode against the same
bucket — answers `302` to a presigned store URL that the shipped ffprobe decodes
to the fixture's duration. The cache outliving the process that filled it is the
difference between this backend and `file://`, and it needs two containers to
show. Reaching `/health` at all is already part of the claim: the boot probe
writes and deletes under a reserved key prefix, so a bucket that refused writes
would never get that far.

## Continuous integration

[`.github/workflows/ci.yml`](../.github/workflows/ci.yml) runs on every push to
`main`, every `v*` tag, and every pull request:

| Job | Needs | Runs | Notes |
|---|---|---|---|
| `test` | — | `mix format --check-formatted`, `mix compile --warnings-as-errors`, starts MinIO, then `mix test --include integration --include minio` | No external *binaries* — the untagged + `:integration` suite must pass on a bare runner |
| `image-ffmpeg` | `test` | Builds the `test` and `runtime` stages, then `mix test --only ffmpeg` inside the image | Asserts the two stages carry the *same* ffmpeg build, and that its major matches [`VERSIONS.md`](../VERSIONS.md) |
| `smoke` | `test` | Builds the release image, runs [`bin/smoke-image`](../bin/smoke-image) | Boot, health, an end-to-end render off a read-only mount, an `s3://` render against MinIO (and `502` once the store is gone), an `s3://` variant store served proxied and then redirected from a second container, a signed percent-escaped URL over h2c, config validation, SIGTERM during a render |
| `capacity` | `test` | Runs [`bin/capacity-matrix --verify`](../bin/capacity-matrix), then builds the release image and runs [`bin/check-capacity`](../bin/check-capacity) twice | Drives a concurrent workload (two-hour source included) and asserts cgroup `memory.peak` stays inside the model [`docs/capacity.md`](capacity.md) publishes; the second run is the guard's own red-path check. The `--verify` step needs no image and checks the other direction — that every cell of that document's decision matrix really is the largest concurrency its column's memory limit holds |
| `hex-package` | `test` | Runs [`bin/check-hex-package`](../bin/check-hex-package) | Builds the tarball, asserts it holds the allowlist and nothing else (LICENSE, `llms.txt`, `llms-full.txt` present; `openspec/`, `test/`, `examples/`, `Dockerfile`, `.github/` absent at any depth), unpacks it outside the checkout and compiles it, then builds the docs and asserts every documented link resolves. Runs on pull requests, because a published hex version is permanent |
| `publish` | `smoke`, `image-ffmpeg`, `capacity`, `license-compliance`, `hex-package` | Pushes to GHCR, and on a tag publishes to hex.pm | Never runs for a pull request; see [Releases](#releases) |

Compilation runs with warnings as errors because the compiler's set-theoretic
type checker reports through warnings — that flag is what makes the type gate a
gate rather than a suggestion.

**The `:ffmpeg` suite runs in exactly one place: inside the image.** There was
briefly a second job running it against Debian's apt ffmpeg on the bare runner,
which was dropped — it tested an encoder this project does not ship. The two
disagree in the way that matters: Debian trixie carries ffmpeg 7.x and the
release image carries 8.x, so a green run against apt could never confirm the
argv contract holds for what actually ships, and a red one might only mean the
old major behaves differently. The cost of dropping it is slower feedback on a
plain argv typo; the benefit is that a pass means something.

Locally, `mix test --only ffmpeg` runs against whatever the devcontainer has
(Debian, 7.x), so treat a local green as a strong hint and CI as the gate. This
is the same gap [`VERSIONS.md`](../VERSIONS.md) documents.

`test` reads Elixir and Erlang/OTP from [`.tool-versions`](../.tool-versions), so
bumping that pin is a one-file change it follows automatically. The
`deps`/`_build` cache is keyed on the resolved versions plus `mix.lock`, so a
toolchain bump misses the cache rather than restoring BEAM files built by a
different compiler. `image-ffmpeg` and `smoke` get their toolchain from the
Dockerfile instead, which is why `VERSIONS.md` has to be bumped alongside
`.tool-versions` — the two are not wired together, and nothing but that file's
procedure keeps them in step.

Later slices extend this workflow rather than adding parallel ones — MinIO as a
service container from `add-s3-client`, and the arm64 matrix from
`add-multi-arch-images` — so there stays one workflow to require.

[`.github/dependabot.yml`](../.github/dependabot.yml) opens update PRs weekly for
Hex packages and GitHub Actions. Minor and patch updates are grouped into one PR
per ecosystem; majors come individually. Every one of them is gated by the
workflow above.

`main` is protected: pull requests cannot merge until the gating jobs pass, and
the branch rejects force-pushes and deletion. **Branch protection is a repo
setting, not a file**, so it does not travel with a clone — a fork has to set it
up again, under *Settings → Branches → Add rule* for `main`, requiring the
checks named **format, compile, unit tests**, **ffmpeg-tagged tests against the
shipped ffmpeg**, **container smoke suite** and **the hex package is what we
meant to ship** (GitHub lists status checks by job name, not by the job's key
in the YAML). `publish` is not a required check — it does not run on pull
requests at all.

> **`hex-package` has to be added to that list by hand.** It gates `publish`
> through `needs:`, which stops a *tag* from publishing a bad tarball but does
> nothing to stop a pull request from merging one — and by the time the tag
> runs, the fix is a new version rather than an edit. Until the rule names it,
> a red `hex-package` is advisory.

> **Renaming or removing a job means editing that list in the same breath.** A
> required check is matched by job name, so one that no longer runs never
> reports, and GitHub shows it as *Expected — waiting for status*: visually
> identical to a job still in progress, on a run that finished minutes ago.
> Every pull request then blocks forever. Dropping the old apt-ffmpeg job did
> exactly this, and the symptom reads as a hung CI rather than a settings
> mismatch, so it costs more to diagnose than it should.

---

## Releases

A release ships two artifacts: the image at `ghcr.io/audioproxy/audioproxy`, and
the hex package [`audio_proxy`](https://hex.pm/packages/audio_proxy) with its
docs on [hexdocs](https://hexdocs.pm/audio_proxy). Nothing is published by hand:
the `publish` job is the only thing that pushes, and it is gated on the smoke
suite, so a red pipeline publishes nothing for that ref.

| Ref | Tags pushed | hex | Mutable? |
|---|---|---|---|
| `vX.Y.Z` | `:X.Y.Z`, `:X.Y`, `:latest` | `audio_proxy X.Y.Z` | `:X.Y` and `:latest` move; `:X.Y.Z` does not, and no hex version ever does |
| push to `main` | `:edge`, `:sha-<12>` | none | `:edge` moves; `:sha-<12>` does not |
| any other `v*` tag | none — the job fails | none | — |

`main` publishes no package because hex has no moving channel to push a
pre-release commit to: the version in `mix.exs` was published by the tag before
it, so every commit after that tag would be a duplicate. `:edge` is the
equivalent for anyone who needs one, and it is an image.

The two artifacts cannot disagree about what they contain. The publish job
asserts `mix.exs` matches the tag before it does anything, and both are built
from that same commit — so `ghcr.io/audioproxy/audioproxy:0.6.0` and
`audio_proxy 0.6.0` are the same code by construction, not by discipline.

**The image is published first, then the package, then the docs** — three
steps, and the order is what makes a partial failure recoverable:

| Failed after | State | Recovery |
|---|---|---|
| the image | image out, nothing on hex | Re-run the job. The image republishes harmlessly (same digest, same tags) |
| the package | image and package out, no docs | Re-run **just the docs**: `MIX_ENV=dev mix hex.publish docs --yes`. Docs have no republish limit |
| nothing | all three out | — |

The package and the docs are two steps rather than one `mix hex.publish` for
exactly that middle row. A published package version can only be overwritten
within an hour of publishing it, and only with `--replace` — so a plain re-run
of a combined command dies on the package half with "already published" and
never reaches the docs it was re-run for.

What cannot be undone is a *successful* bad publish. `mix hex.publish --revert
VERSION` works for one hour (24 for a brand-new package) and after that
`mix hex.retire` only marks a version rather than removing it. That asymmetry
is why [`bin/check-hex-package`](../bin/check-hex-package) runs on every pull
request instead of only at the tag.

### The hex credentials

Publishing needs a `HEX_API_KEY` repository secret, and it is the one part of
the release path that is set up by hand.

**The key is generated on hex.pm, not from the CLI.** Hex has no
user-key task — `mix hex.user` does `whoami`, `auth` and `deauth` and nothing
else (checked against hex 2.5.1). The page is
[hex.pm/dashboard/keys](https://hex.pm/dashboard/keys), signed in, and it is
not linked from anywhere obvious:

1. **Generate New Key**
2. A key name — `publish-ci`
3. An expiration (see below)
4. Under **Key permissions**, check **Write** beneath **API**
5. **Generate Key**

The value is shown once, at creation.

**Whatever expiration you pick is a future release failure with a date on it.**
When the key lapses, the tag pushes the image and then fails on the hex step —
the loud-but-late half of the partial state above, months after anyone
remembers setting it. Pick a length you will notice, and treat the renewal as
part of the release calendar rather than something to discover at a tag.

Two things that are *not* the route here, both of which look like it:

- `mix hex.user auth` mints a key, but stores it encrypted in
  `~/.hex/hex.config` for that machine — there is no plaintext to copy.
- `mix hex.organization key ORG generate --key-name … --permission api:write`
  is the organization-level equivalent, and this project deliberately has no
  hex organization (see the change's *Goals / Non-Goals*). `audio_proxy` is a
  personal-account package, so its key is a user key from the dashboard.

Put the generated value in **Settings → Secrets and variables → Actions** as
`HEX_API_KEY`. Give it write access to the API and nothing more: it is a
publish credential, not an account credential, and it can be revoked from the
same page without touching the account or the other keys.

A tag pushed before that secret exists fails the publish job **after** the image
has been pushed — deliberately loud, because a release that quietly shipped one
of its two artifacts is the state worth failing about. If you are cutting the
first release, confirm the secret is there before tagging.

That last row is deliberate. The workflow triggers on `v*`, so `v1.2.3-rc1` and
`v1.2` reach the publish job, and both would otherwise have been treated as
releases: an RC would have moved `:latest`, and `v2.0.0-beta.1` would have
produced a `:2.0.0-beta` tag that means nothing. There is no pre-release channel
yet; if one is wanted, it needs its own tag rule rather than falling out of
string manipulation.

`:sha-<12>` is the one to reach for when you need an exact image that is not a
release — it is one image per commit and it is never reused, which makes both
pinning and bisection possible.

### Cutting a release

```bash
# 1. Bump the version in mix.exs. CI fails the publish if it disagrees
#    with the tag, so this is not optional and not automated.
$EDITOR mix.exs

# 2. Land it on main through the usual PR gate.

# 3. Dry-run the package. Builds the tarball, checks its contents and
#    compiles it outside the repo. Uploads nothing.
bin/check-hex-package

# 4. Tag the merge commit and push the tag.
git tag -a v0.1.0 -m "v0.1.0"
git push origin v0.1.0
```

The tag push runs the whole pipeline again — tests, image, smoke — and only
then publishes. There is no separate release workflow to keep in step.

Step 3 is belt-and-braces: the same script gates every pull request, so a
tarball that has gone wrong should already have failed there. It is in the
procedure because the cost of the two is not symmetric — a minute locally
against a permanent version on hex.

Afterwards, confirm all four names agree: the git tag, `mix.exs`, the image tag
on GHCR, and the version on [hex.pm](https://hex.pm/packages/audio_proxy) with
its docs rendered on [hexdocs](https://hexdocs.pm/audio_proxy).

### Owed to the next release's notes

A change that alters the bytes an *unchanged* URL renders is owed a line in the
release notes, because nothing else will tell an operator: the URL is the same,
the cache key is the same, and a warm CDN and a cold one will disagree about
what they serve until the old objects age out. This section is where such a
line waits between merging and being cut, and an entry is deleted by the
release that carries it — an empty section is the normal state.

- **`norm` without an explicit `sr` now renders at the source's sample rate**
  rather than at a flat 48 kHz (`peaks-follow-the-variant`). A normalized
  variant of a 44.1 kHz source, or of a 96 kHz master, is different bytes under
  the same key than the release before it. Two consequences for the release
  itself: say so in the notes, and **purge the playground's variant store**
  before announcing, so the demo does not keep serving 48 kHz variants that
  contradict the documentation. The change was taken deliberately while no
  third-party deployment exists — see that change's proposal for the argument,
  and for why the same fix after the first real deployment would have needed a
  cache-busting story instead.

**Release notes are claims, and claims name their checks.** Before publishing
notes, every Highlight must point at the automated check that demonstrates it —
a smoke assertion, a tagged suite, a named test. A feature no check exercises
does not go in the Highlights, however merged it looks; it goes under Known
gaps, or the check gets written first. This rule exists because v0.3.0's notes
announced S3 rendering while `Source.S3` still answered `no_backend`: the
change had been archived with the gap honestly recorded, the stub was pinned
by a green test, and the smoke suite rendered `local://` only — every signal
was green and the claim was still false. Notes written from the board instead
of from a check inherit exactly that failure.

### What bumps what

SemVer here is over the **URL contract**: the grammar, the response semantics,
and the cache-key derivation. That is the API this project has; the Elixir
modules are not a public interface.

| Change | Bump |
|---|---|
| New option, new format, new endpoint — nothing existing changes meaning | Minor |
| A change to what an existing URL means, or to how a cache key is derived | **Major** |
| Bug fix, dependency update, ffmpeg/Debian/OTP pin bump | Patch |

Two of those are worth spelling out, because both look smaller than they are:

- **A cache-key change is major even though no client code changes.** New keys
  orphan every variant already written to the cache: the URLs still work, and
  every one of them silently re-renders and re-writes. An operator has to be
  told that before it happens, and a major version is how.
- **A pin bump cuts a release.** A different ffmpeg encodes the same URL to
  different bytes. Someone tracking `:0.1` must not have the output of a URL
  change under them without a version to point at, so the pin is part of what a
  version identifies. The procedure is in
  [VERSIONS.md](../VERSIONS.md#bumping-a-pin).

Until `v1.0.0` the URL contract may still move; `0.x` is the signal that it is
not yet frozen.

---

## Per-slice worktrees

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
the hooks in [`.config/wt.toml`](../.config/wt.toml).

The devcontainer image
([`.devcontainer/Dockerfile`](../.devcontainer/Dockerfile)) pins the same
Elixir/OTP pair as `.tool-versions`, plus `ffmpeg`/`ffprobe` — they are part of
the product, so the `:ffmpeg`-tagged tests need the real binaries.

Since `add-s3-client` the devcontainer is a **compose project**
([`.devcontainer/docker-compose.yml`](../.devcontainer/docker-compose.yml)):
an `app` service built from that Dockerfile, and a `minio` service for the
`:minio` suite. The devcontainer CLI derives the compose project name from
the workspace folder, so each worktree gets its own `app` *and* its own
`minio` with no shared state. MinIO publishes no host port for exactly that
reason — only `app` reaches it, over the compose network at `minio:9000` — so
parallel worktrees cannot collide on 9000.

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
