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
| `image-ffmpeg` (×2) | `test` | Builds the `test` and `runtime` stages, then `mix test --only ffmpeg` inside the image | Asserts the two stages carry the *same* ffmpeg build, and that its major matches [`VERSIONS.md`](../VERSIONS.md). Once per architecture; each leg records the full ffmpeg version as an artifact |
| `ffmpeg-arch-parity` | `image-ffmpeg` | Compares the two recorded ffmpeg versions | The architectures must ship the *same* Debian ffmpeg, not merely the same major. See [`VERSIONS.md`](../VERSIONS.md) for what to do the day they diverge |
| `smoke` (×2) | `test` | Builds the release image, runs [`bin/smoke-image`](../bin/smoke-image) | Boot, health, an end-to-end render off a read-only mount, an `s3://` render against MinIO (and `502` once the store is gone), an `s3://` variant store served proxied and then redirected from a second container, a signed percent-escaped URL over h2c, config validation, SIGTERM during a render |
| `capacity` | `test` | Runs [`bin/capacity-matrix --verify`](../bin/capacity-matrix), then builds the release image and runs [`bin/check-capacity`](../bin/check-capacity) twice | Drives a concurrent workload (two-hour source included) and asserts cgroup `memory.peak` stays inside the model [`docs/capacity.md`](capacity.md) publishes; the second run is the guard's own red-path check. The `--verify` step needs no image and checks the other direction — that every cell of that document's decision matrix really is the largest concurrency its column's memory limit holds |
| `hex-package` | `test` | Runs [`bin/check-hex-package`](../bin/check-hex-package) | Builds the tarball, asserts it holds the allowlist and nothing else (LICENSE, `llms.txt`, `llms-full.txt` present; `openspec/`, `test/`, `examples/`, `Dockerfile`, `.github/` absent at any depth), unpacks it outside the checkout and compiles it, then builds the docs and asserts every documented link resolves. Runs on pull requests, because a published hex version is permanent |
| `license-compliance` (×2) | `test` | Builds the release image and reads its notices back | Asserts every installed package ships a `/usr/share/doc/*/copyright`, that `SOURCES.txt` matches this image's own dpkg, and that a sample of its source URLs resolves. Once per architecture, because `SOURCES.txt` is generated inside the image and lists that architecture's packages |
| `meta` | — | Computes the version and the tag list once | Only on a push to `main` or a `v*` tag; the `if` that keeps publishing off pull requests lives here, and skipping it skips everything below |
| `image-build` (×2) | `meta` and every check above | Builds the release image per architecture and pushes it to GHCR **by digest**, untagged | What reaches the registry here is unreachable by `docker pull`; nothing is named until the stitch below |
| `publish` | `meta`, `image-build` | Stitches the per-arch digests into one manifest list per tag, then on a tag publishes to hex.pm | Refuses to run with fewer than two digests, and reads every tag back with `imagetools inspect` to confirm both platforms are listed. Never runs for a pull request; see [Releases](#releases) |
| `verify-published` (×2) | `publish` | Pulls the published tag with no `--platform` and boots it | On each architecture's own runner: the pull must resolve to that architecture and the release must answer `/health` |

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

Later slices extend this workflow rather than adding parallel ones — MinIO from
`add-s3-client`, the arm64 matrix from `add-multi-arch-images` — so there stays
one workflow to require. Both have landed. MinIO arrived as a `docker run` in
the `test` job rather than as a `services:` container, for the reason the
comment beside it gives: the image needs a command (`server /data`) and the
services block has nowhere to put one.

### Two architectures

A published tag is a **manifest list** holding `linux/amd64` and `linux/arm64`,
so `docker pull` resolves to a native image on Graviton, Ampere and Apple
Silicon without anyone passing `--platform`. Four things follow from that, and
all four are decisions rather than incidental mechanics.

**Native runners, not QEMU.** The arm64 legs run on `ubuntu-24.04-arm`, GitHub's
hosted arm64 machines. Emulated builds are 5–20× slower, and the BEAM's JIT
under QEMU is a known flake source — which would put emulation artifacts
squarely in the middle of the one suite whose job is to tell a real boot failure
from a fake one. The arm64 image is built and exercised by an arm64 machine or
it is not published. The amd64 side stays on `ubuntu-latest`; the arm side names
a concrete image because there is no floating `-arm` alias to point at.

**Nothing is named until both architectures are green.** `image-build` pushes
*by digest* — the image reaches GHCR carrying no tag, so no `docker pull` can
reach it — and `publish` is the only job that stitches those digests into a
manifest list and attaches the tags. If either architecture fails, `publish`
never runs and not one tag moves. The obvious alternative, tagging per
architecture and merging afterwards, publishes a single-arch `:latest` for the
width of the window in between, and a pull landing in that window silently gets
emulation or an error. The digest count is asserted in the stitch step itself
rather than left to `needs:`, because a matrix leg that never ran leaves a
directory with one digest in it and `imagetools create` over one digest
succeeds — which is exactly the partial manifest this arrangement exists to
prevent.

**The buildx layer cache is scoped per architecture.** Two architectures sharing
one cache scope evict each other on every run: the layers differ all the way
down. Two *jobs* of the same architecture sharing a scope is the reuse worth
having, and that is what the `scope=${{ matrix.arch }}` on every image build
keeps.

**Renders are not asserted to be byte-identical across architectures, and this
is deliberate.** ffmpeg may legitimately emit different bytes for the same input
on different hardware — float rounding, different SIMD paths — and the per-arch
contract is the same one the smoke suite already states: the output decodes, its
duration is right, and the ffmpeg major is the pinned one. The consequence
belongs to operators rather than to CI: **a mixed-arch fleet sharing one variant
bucket can serve two byte-different renders under one cache key**, depending on
which node rendered first. That is the same variance an ffmpeg patch bump
introduces, it is invisible to any client that decodes rather than hashes, and a
deployment that genuinely needs byte-stability pins one architecture. What *is*
asserted is that both architectures ship the same ffmpeg — see
[`VERSIONS.md`](../VERSIONS.md) — so the variance stays down at the level of
arithmetic and never becomes a difference of encoder.

The devcontainer needs nothing from any of this: its base images already exist
for both architectures, so a worktree on an Apple Silicon machine builds arm64
locally and one on an x86 machine builds amd64, with no flag either way.

[`.github/dependabot.yml`](../.github/dependabot.yml) opens update PRs weekly for
Hex packages and GitHub Actions. Minor and patch updates are grouped into one PR
per ecosystem; majors come individually. Every one of them is gated by the
workflow above.

`main` is protected: pull requests cannot merge until the required checks pass,
and the branch rejects force-pushes and deletion. The required set is derived
rather than chosen: **everything that gates a tag also gates a merge**, so a
commit that could not be published cannot reach `main` either. Concretely that
is every job `publish` transitively `needs:` that runs on a pull request,
expanded the way GitHub names it — status checks are listed by job *name*, not
by the job's key in the YAML, and a matrix job reports one check per leg, with
the leg in the name:

<!-- required-checks-table:start -->
| Check | Required to merge | Notes |
|---|---|---|
| `format, compile, unit tests` | `yes` | |
| `ffmpeg-tagged tests against the shipped ffmpeg (amd64)` | `yes` | |
| `ffmpeg-tagged tests against the shipped ffmpeg (arm64)` | `yes` | |
| `both architectures ship the same ffmpeg` | `yes` | |
| `container smoke suite (amd64)` | `yes` | |
| `container smoke suite (arm64)` | `yes` | |
| `the published memory model holds` | `no` | Deliberately advisory: `capacity` drives a concurrent workload with a two-hour source, and paying that wait on every merge is a cost decision, not an oversight. It still gates every publish through `needs:`. |
| `the hex package is what we meant to ship` | `yes` | |
| `the image carries its notices and its source manifest (amd64)` | `yes` | |
| `the image carries its notices and its source manifest (arm64)` | `yes` | |
<!-- required-checks-table:end -->

`publish` and `verify-published` are absent because they never run on a pull
request, and `meta` and `image-build` are skipped there too — a check that
never reports cannot be required.

**Branch protection is a repo setting, not a file**, so it does not travel with
a clone: a fork has to recreate the rule under *Settings → Branches → Add
rule* for `main`, requiring every check the table marks `yes`.

The table is compared against the workflow by
[`test/required_checks_test.exs`](../test/required_checks_test.exs), which
derives the gating job names from `ci.yml` — matrix legs expanded — and fails
on disagreement in either direction, inside the `test` job like any other
drift guard. A check the workflow produces but the table omits is an ungated
merge; a check the table names that the workflow no longer produces is a rule
that blocks every pull request forever, showing *Expected — waiting for
status*: visually identical to a job still in progress, on a run that finished
minutes ago. Dropping the old apt-ffmpeg job did exactly that, and the symptom
read as a hung CI rather than a settings mismatch. Renaming a job, putting one
in a matrix, or adding an architecture all rename checks the same way, and all
now land in this table as a red `test` job first.

> **The guard checks this document, not the repo setting.** Nothing short of
> admin scope can read or write the rule itself — and a workflow that could
> rewrite its own merge gate would be a worse problem than the drift it
> prevents. So the division of labour is: the guard keeps these *instructions*
> right, and a human keeps the *rule* matching them. When this table changes,
> editing the branch-protection rule on `main` in the same breath is part of
> the change, not a follow-up.

### One publish at a time

The publish-side jobs — `meta`, `image-build`, `publish` and `verify-published`
— share a single `concurrency:` group keyed by `github.ref`. Everything above
them stays ungrouped.

The reason is that a moving tag is shared state. `:edge` moves on every push to
`main`, and `:latest`/`:X.Y` move on a release; the immutable `:sha-<12>` tags
do not, because they name their own commit. Without a group, two pushes landing
close together run two whole pipelines that each stitch their own digests onto
those tags, and the tag ends up naming whichever pipeline happened to finish
last — which is not necessarily the newer commit. Publishing is now a four-job
pipeline with an artifact round-trip in the middle, so the window in which one
run can overtake another is minutes rather than seconds. Serialized, the second
run waits for the first, and a moving tag names the newest commit that finished
publishing.

Keying by ref rather than by workflow gives one queue for `main` and one per
release tag: they touch disjoint tag sets and have no reason to wait on each
other.

**`cancel-in-progress` is `false`, and that is the part worth reading twice.**
The reflex everywhere else is `true` — superseded work is wasted work — and
here it would be actively harmful. Cancelling a run mid-`publish` can leave some
tags of a release stitched and others not, which is precisely the partial state
the digest-then-stitch split exists to prevent. A publish that has begun is
allowed to finish; the next run supersedes it in an orderly way. Queued runs do
not pile up either: GitHub keeps only the most recent *pending* run per group
and cancels the older pending ones, which is the right trade — work that has not
started is worth nothing.

The verification jobs are exempt on purpose. They are pure functions of a
commit, they write nothing outside their own run, and they are the bulk of the
wall clock; serializing them would double the cost of a busy day and protect
nothing.

The arrangement is held in place by
[`test/publish_concurrency_test.exs`](../test/publish_concurrency_test.exs),
which derives the publish-side set from the workflow rather than listing it —
a job that cannot run for a pull request is downstream of `meta`’s push-only
`if:`, and so is part of the publish half — and asserts the biconditional:
every such job carries the ref-keyed group with `cancel-in-progress: false`,
and no job that runs on a pull request carries one at all. What it cannot
assert is that GitHub honours the key; that is GitHub’s behaviour, and what is
ours is the workflow declaring it.

What this does *not* fix: a multi-`--tag` `imagetools create` is not atomic, so
a call that fails part-way can move some tags and not others. That is inherited
from the single-step push and is a different problem.

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
from that same commit — so `ghcr.io/audioproxy/audioproxy:0.7.1` and
`audio_proxy 0.7.1` are the same code by construction, not by discipline.

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

- **Multi-arch images** (`add-multi-arch-images`). Every tag from this release on
  is a manifest list carrying `linux/amd64` and `linux/arm64`, so a host that
  was pulling an amd64 image under emulation starts pulling a native arm64 one
  without changing anything. The two encode the same URL to bytes that may
  differ — not audibly, and not in duration or format, but they are not the same
  bytes — so **a fleet running both architectures against one variant bucket can
  hold either render under a given cache key**, decided by whichever node
  rendered first. Nothing re-renders and no URL changes meaning; an operator who
  hashes variants rather than decoding them needs to know, and one who needs
  byte-stability pins a single architecture. Checked by `verify-published`,
  which pulls the primary published tag on each architecture and boots it, and
  by `ffmpeg-arch-parity`, which holds both architectures to the same ffmpeg.
  (Every tag is checked for both platforms, by `imagetools inspect` in
  `publish`; it is the pull-and-boot that takes one tag as the sample.)

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
