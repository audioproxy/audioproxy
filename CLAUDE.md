# Audio Proxy (working title)

An imgproxy-style on-the-fly audio transcoding proxy. Reads source files from S3, renders variants (transcodes, trimmed previews, waveform peaks) on demand, streams them to the client, and writes them back to a variant bucket for cached, range-capable serving.

The full API design lives in `docs/audio-proxy-api-v1.md` — read it before touching URL parsing, options, or response semantics. It is the source of truth for endpoints, processing options, cache-key rules, headers, and error codes.

## Stack — decided, don't relitigate

- **Elixir**, Plug + **Bandit** (no Phoenix — no HTML, no channels needed)
- **ffmpeg via subprocess** (Port), not libav bindings. ffmpeg does all decoding/encoding; the Elixir side is orchestration only.
- `ffprobe` for the `/info` endpoint.
- **Single Docker container**: multi-stage build, `mix release` with bundled ERTS, `apk add ffmpeg` in the runtime stage. No sidecar, no external queue, no database.
- S3 access via a minimal SDK (evaluate `ex_aws_s3` vs `req` + `aws_signature`); presigned URLs are essential (see below).

## Dependency policy

Stay with the stdlib and core/OTP tooling as far as possible. GenStage is acceptable (core-team-maintained) if a real demand-driven pipeline emerges; do NOT pull in Exile, Membrane, Broadway, or Phoenix without discussing it first. Prefer boring OTP: GenServer, Registry, Task, DynamicSupervisor.

## Dev workflow

- **Every feature/slice starts on a fresh git worktree paired with a devcontainer**, managed with worktrunk (`wt`). This is the Elixir adaptation of the `/jr-rails-new` agentic-worktree workflow (see that skill's `reference/agentic-worktrees.md` for the principal pattern):
  - `.config/wt.toml`: `post-create` runs `bin/agent-setup` (deps + compile inside the devcontainer), `post-start` runs `PORT={{ branch | hash_port }} bin/agent-server`, `pre-remove` runs `bin/agent-cleanup`, `post-remove` kills the branch's listener.
  - `bin/agent-server` boots the app on the branch's hashed port (Bandit reads `PORT`). No per-branch database exists — the app is stateless, so worktree isolation is just directory + port.
  - Devcontainer image carries Elixir/OTP + ffmpeg/ffprobe (mirrors runtime deps); `postCreateCommand` is `bin/agent-setup`. Use `devcontainer up` / `devcontainer exec`, not raw `docker compose`.
- One OpenSpec change per worktree; merge back when its tasks are checked off and tests are green.
- Local toolchain (outside containers) is pinned with mise (`mise.toml` / `.tool-versions`), Elixir/OTP as a matched pair.
- Keep the README current: every slice that changes behavior, options, config, or workflow updates it in the same change.

## Architecture decisions

- **Input side:** never pipe source bytes through the BEAM. Generate a presigned S3 URL and pass it to ffmpeg as an HTTP input — ffmpeg does its own Range requests, so `-ss` seeks and trims read only the bytes they need. Also avoids the stdin/MP4-moov-atom trap.
- **Output side:** ffmpeg writes encoded output progressively; only streamable containers by default (mp3, ADTS AAC, Ogg/Opus). MP4 family only as fragmented MP4 (`-movflags frag_keyframe+empty_moov`).
- **Backpressure:** start with raw `Port` + a bounded-buffer GenServer (preview-sized outputs make mailbox pressure a non-issue). For full-length transcodes, the escalation path is the named-pipe (FIFO) pattern: ffmpeg writes to a `mkfifo` pipe, Elixir reads it passively with `File.open`/`IO.binread` in raw mode — OS pipe blocking gives true backpressure, zero deps. OTP ≥21 file reads run on dirty I/O schedulers.
- **Render policy:** render at full speed into the S3 write-back; the client's chunked stream lags the render rather than throttling it (a slow client must not pin a CPU slot at listening speed).
- **Concurrency:** semaphore/counting GenServer capping concurrent ffmpeg processes at `AP_MAX_CONCURRENCY` (default: schedulers online). Bounded wait queue → 429.
- **Coalescing:** one render process per in-flight cache key via `Registry`; all concurrent requests for the same variant subscribe to its chunk broadcast; late joiners catch up from the partial data.
- **Cache semantics:** MISS = 200 chunked (no Range) + tee to variant bucket; HIT = 302 to presigned variant URL (default) so S3/CDN serves Range/206. All per the API doc §5.

## Module shape (target, not gospel)

signature verification plug → options parser (options string = normalized cache key) → source resolver / S3 layer → render supervisor + coalescing registry → ffmpeg pipeline (Port wrapper) → chunked delivery / redirect.

## Conventions

- Config via env vars only, `AP_`-prefixed, per API doc §6.
- Every processing option must round-trip: parse → normalize → cache key → identical ffmpeg args. Property-test this.
- ffmpeg arg construction must be injection-safe: argv lists only, never shell strings.
- Kill the ffmpeg process on client disconnect and on `AP_RENDER_TIMEOUT`; no orphans.
- **Typing:** Elixir ≥ 1.20 — the built-in set-theoretic checker plus `mix compile --warnings-as-errors` in CI is the type gate; no Dialyzer/dialyxir. Write `@type t` / `@spec` on public seams only (`Options`, `Source`, `Signature`, `Command`, the `S3` behaviour) for ExDoc/LSP; skip private plumbing. Migrate to native typed structs/contracts when they land (1.21+).
- **Commits are atomic and follow [Conventional Commits](https://www.conventionalcommits.org).** One logical change per commit, each compiling with `mix test` green on its own — never a broken intermediate state that a later commit repairs. Scopes track the module or area touched (`feat(config):`, `feat(http):`, `build(devcontainer):`). Prefer a vertical slice (code plus its tests) over splitting code from the tests that cover it. Types in use: `feat`, `fix`, `refactor`, `perf`, `test`, `docs`, `build`, `ci`, `chore`.

## Open questions (decide as they come up)

- ~~Project/binary name~~ — settled for now: OTP app `audio_proxy`, still a working title. Renaming is a cheap find/replace while the project is small.
- `ex_aws_s3` vs hand-rolled signing with `req`.
- Peaks output: exact JSON schema (audiowaveform compatibility?).
- Single-pass `loudnorm` accuracy — good enough for previews, revisit for masters.
- **Distro ffmpeg vs compiled from source.** Currently distro packages: devcontainer is `apt install ffmpeg` on debian trixie (7.1.5), the release image will be `apk add ffmpeg` on alpine. Building from source would buy an exact pinned version identical in dev and prod, a `--disable-everything` codec set trimmed to what the API actually offers (smaller image, smaller attack surface), and access to encoders Debian/Alpine omit on licensing grounds (`libfdk_aac`). It costs a long build stage, a hand-maintained codec list, and the security-patch duty that distro packaging otherwise handles. Decide in `add-docker-release`; if the answer is yes, the devcontainer must build the same way or dev and prod diverge on codec behaviour.
- HLS (v2): URL space is reserved, nothing else designed.
