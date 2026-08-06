# Audio Proxy (working title)

An imgproxy-style on-the-fly audio transcoding proxy. Reads source files from S3, renders variants (transcodes, trimmed previews, waveform peaks) on demand, streams them to the client, and writes them back to a variant bucket for cached, range-capable serving.

The full API design lives in `docs/audio-proxy-api-v1.md` — read it before touching URL parsing, options, or response semantics. It is the source of truth for endpoints, processing options, cache-key rules, headers, and error codes.

## Worktree gate — check this before the first edit of any task

**Never edit files while `main` is checked out.** Every change — feature, fix, docs, config — starts on its own worktree. The exception is *planning*, below.

Before your first write or edit of a task, run `git branch --show-current`. If it prints `main`, stop and create the worktree first:

```bash
wt switch --create <change-name>   # then work in ../audioproxy.<change-name>
```

This is a precondition, not a preference. "It's only a config file", "it's just docs", and "I'll branch once I know what to change" are all violations. Reading, searching, and running the suite on `main` are fine; writing is not.

**Writing a proposal is planning, and planning happens on `main`.** Creating or editing an OpenSpec change's *artifacts* — `proposal.md`, `design.md`, `tasks.md`, the delta specs under `specs/` — is a `main` activity, committed straight to `main` as `docs(openspec):`. Nothing is implemented yet, there is nothing to run, and several proposals routinely land in one commit; a worktree and a devcontainer per proposal buys isolation for work that touches no code. The worktree comes later, when `/opsx:apply` starts *implementing* the change — and from then on that change's artifacts move with it, tasks getting checked off on the branch alongside the code they describe.

The other writes permitted on `main`: resolving a merge, and the commit `/opsx:archive` produces for an already-merged change.

Workflow mechanics (devcontainer, ports, hooks) are under *Dev workflow* below.

## Stack — decided, don't relitigate

- **Elixir**, Plug + **Bandit** (no Phoenix — no HTML, no channels needed)
- **ffmpeg via subprocess** (Port), not libav bindings. ffmpeg does all decoding/encoding; the Elixir side is orchestration only. This is also the licensing posture: the (L)GPL boundary is a *process* boundary, so `audio_proxy` is a distinct program invoking a CLI and even a GPL-configured ffmpeg imposes nothing on this source tree. A future proposal to switch to NIF-based libav bindings "for performance" therefore changes the licensing analysis too, and has to be argued on both.
- `ffprobe` for the `/info` endpoint.
- **Single Docker container**: multi-stage build, `mix release` with bundled ERTS, `apt-get install ffmpeg` in the runtime stage. No sidecar, no external queue, no database.
- **Debian slim, not Alpine — and this is not a preference to revisit for image size.** The image was Alpine first. On musl the BEAM intermittently aborts at startup (`sys_sigaltstack(): Failed to set alternate signal stack`, exit 134), measured at 2 failures in 10 runs on GitHub's runners, in the *runtime* container — the shipped image failing to boot. OTP's fix for it only ever worked against glibc. Debian costs ~80 MB and buys a release that starts. `VERSIONS.md` has the evidence; anyone proposing a return to Alpine has to answer it.
- **S3 access via `ex_aws_s3`** — settled in `add-s3-client`, see *Open questions* for the argument. `AudioProxy.S3` is a four-function facade over it so the surface stays small and the error vocabulary stays ours. Presigned URLs are essential (see below).

## Dependency policy

Stay with the stdlib and core/OTP tooling as far as possible. GenStage is acceptable (core-team-maintained) if a real demand-driven pipeline emerges; do NOT pull in Exile, Membrane, Broadway, or Phoenix without discussing it first. Prefer boring OTP: GenServer, Registry, Task, DynamicSupervisor.

## Dev workflow

- **Every feature/slice starts on a fresh git worktree paired with a devcontainer** (see *Worktree gate* above — that rule is the enforcement, this is the mechanism), managed with worktrunk (`wt`). The pattern is one isolated checkout per slice, each with its own container and its own port, so parallel agent sessions cannot collide:
  - `.config/wt.toml`: `post-create` runs `bin/agent-setup` (deps + compile inside the devcontainer), `post-start` runs `PORT={{ branch | hash_port }} bin/agent-server`, `pre-remove` runs `bin/agent-cleanup`, `post-remove` kills the branch's listener.
  - `bin/agent-server` boots the app on the branch's hashed port (Bandit reads `PORT`). No per-branch database exists — the app is stateless, so worktree isolation is just directory + port.
  - Devcontainer image carries Elixir/OTP + ffmpeg/ffprobe (mirrors runtime deps); `postCreateCommand` is `bin/agent-setup`. Use `devcontainer up` / `devcontainer exec`, not raw `docker compose`.
- One OpenSpec change per worktree; merge back when its tasks are checked off and tests are green.
- **A deferral is a change, created in the same commit.** Descoping mid-implementation is fine; a "Deferred out of this change" note in an archived change is not a plan. Whatever is deferred gets its own change on the board *before* the archive lands, and the deferral note names it. (v0.3.0 shipped release notes for deferred work because the deferral lived only inside an archived file no planner reads.)
- Toolchain pin lives in `.tool-versions`, Elixir/OTP as a matched pair. It is the single source of truth: mise reads it locally, `erlef/setup-beam` reads it in CI. Bumping a version means editing that one file (and the devcontainer/release image tags by hand).
- **Documentation has a shape; keep writing to it.** Every slice that changes behavior, options, config, or workflow updates the docs in the same change — but *which* doc is not a free choice:

  | File | Holds | Test |
  |---|---|---|
  | `README.md` | Usage only. What the proxy is, how to sign a URL, every option and its validation rules, configuration, how to run it. | Would someone *operating* this need it? |
  | `docs/audio-proxy-api-v1.md` | The source of truth for URL grammar, options, cache-key rules, headers, error codes. | Is this the contract? |
  | `docs/development.md` | Toolchain, worktrees and devcontainers, the suite and its tags, CI. | Is this about working *on* the repo? |
  | `docs/ffmpeg-arguments.md` | How options become ffmpeg args: filter order, per-format flags, measured trade-offs, known gaps. | Is this how the sausage is made? |

  The README is the one with a hard rule: **no implementation detail.** A reader arrives wanting to render audio, not to learn how the filtergraph is assembled. Internals that are genuinely worth writing down — and most are — go to `docs/` and get linked from the README's documentation table, not inlined into it. When a section starts explaining *how* rather than *how to*, it has outgrown the README.

## Adversarial review — how this project does it

"Do an adversarial review" (or "second opinion") on this repo means one specific thing: **delegate the review to the `opencode` CLI running a non-Claude model, then reconcile its findings against your own self-review.** Do not substitute an in-session review or a subagent — the entire value is that the reviewer is a different model that did not write the code. Findings from past rounds that a self-review missed entirely (a float-comparison bug, a silently dropped struct field) are why this is the rule.

The loop is: write your own review first, run the CLI, reconcile the two, then act only on what survives. What follows is what this project has learned about running it, so it is not rediscovered every time.

**Invocation** — from the worktree under review, backgrounded, never in the foreground. `$SCRATCH` is any scratch directory outside the repo:

```bash
opencode models | grep kimi                   # verify the id resolves before the real run

cat > "$SCRATCH/oc-config.json" <<'JSON'
{
  "$schema": "https://opencode.ai/config.json",
  "permission": {
    "bash": "allow", "glob": "allow", "grep": "allow", "read": "allow",
    "external_directory": "allow",
    "edit": "deny", "write": "deny", "patch": "deny"
  }
}
JSON

cd <worktree> && OPENCODE_CONFIG="$SCRATCH/oc-config.json" \
  nohup opencode run --print-logs -m opencode-go/kimi-k2.7-code \
  --title "second-opinion-<change-name>" "$(cat "$SCRATCH/brief.md")" \
  > "$SCRATCH/review.md" 2> "$SCRATCH/review.err" &
```

If the agent harness runs a non-login shell, `opencode` may not be on its `PATH`; prepend the directory it actually lives in rather than assuming the inherited environment is the interactive one.

- **Model:** `opencode-go/kimi-k2.7-code`. First-party ids are flat; OpenRouter's need the vendor path (`openrouter/moonshotai/kimi-k2.7-code`, never `openrouter/kimi-k2.7-code`, which fails slowly and silently). Prefer a first-party route where one exists — an aggregator that degrades presents as an unexplained hang, and swapping the route is a one-flag way to rule that out. Fallbacks: `openrouter/deepseek-v4-pro`, `openai/gpt-5.6-pro`.
- **`--print-logs` on every run.** It puts structured logs on stderr and leaves the answer on stdout, which is the only way to tell a working run from a hung one — both are a 0-byte output file otherwise. Poll `review.err` and watch `message=loop step=N` advance. It is a diagnostic, not a fix: a run that seems to start working when you add it was working already.
- **Override the tool permissions for the run.** If opencode's user config denies `bash`/`glob`/`grep`/`read` — a reasonable thing to do when MCP equivalents are preferred — `opencode run` hangs forever at `message=init` with a 0-byte output file, because a review needs to read the code and has no way to. Override per-run via `OPENCODE_CONFIG` as above; **never edit the user's own config.** Denying `edit`/`write`/`patch` in that same override is also the only no-write guarantee opencode has, since no flag provides one.
- **`external_directory` must be allowed too, and its absence is a *third* failure mode.** Left out, the run dies mid-review with `Error: The user rejected permission to use this specific tool call.` — because a permission whose verdict is `ask` cannot be asked non-interactively, so it is refused, and the refusal aborts the whole run rather than just that call. The reviewer earns it honestly: it redirects `git diff main...HEAD` to a file under `/tmp` and then tries to read it back, which is a read outside the project directory. Tell it apart from the other two by the log — `evaluated permission=external_directory ... action.action=ask` followed by `message=asking`, at a step count well past init, with an exit rather than a hang. Bash is what wrote the file, so this permission is not a write hole: `edit`/`write`/`patch` stay denied and the post-run `git status --short` still proves nothing in the repo moved.
- **Smoke-test with a prompt that uses a tool** (`"Run 'git rev-parse --abbrev-ref HEAD' and reply BRANCH=<name>"`). A tool-less "reply OK" prompt passes under a config that makes review impossible, and has burned a whole session that way. It will not catch the `external_directory` case above, which needs a *review-shaped* prompt to surface — so a green smoke test means the model can read code, not that the run will finish.
- **Commit before running** so `git status --short` afterwards proves the reviewer mutated nothing.
- Runs take 5–20 minutes and are I/O-bound. A stalled byte count plus a live process is normal mid-thought.

**A clean exit with an empty output file is a distinct failure — do not confuse it with the hang above.** A reasoning model can spend its entire final turn thinking and never emit a text part: exit 0, a full log ending in `exiting loop`, several completed steps, and nothing to print. Observed at 131,000 characters of reasoning, much of it degenerating into repetition, with no answer at the end. The two failures share the 0-byte symptom and nothing else — tell them apart by exit status and log tail, never by the size of the output file. Two consequences:

- **The brief must demand the findings as the final message** — "think briefly, then write; if you are running long, write what you have." This is the actual prevention: three consecutive runs returned nothing, and the first run carrying that instruction returned a review that found a real bug. It has since held on every run that carried it, including one that spent ~90 s composing after its last tool call before anything appeared on stdout — so the answer arriving all at once at the end is what success looks like, not a symptom.
- **Recover rather than re-run.** Recent opencode keeps sessions in a SQLite database under its data directory; the analysis sits in the `part` table and can be pulled out with `sqlite3` and mined with `grep` for severity markers, which beats paying another 5–20 minutes for a result that may fail the same way. Treat what comes back as findings, not as a review — it never went through whatever produces the final answer, so it carries lines of thought the model later abandoned.

**Brief** — always include: the artifact (`git diff main...HEAD` on the worktree), hunting priorities in order, H/M/L severity on *every* finding, a **quoted snippet** per finding rather than a bare `file:line` (see below), "do not edit any files", the findings-as-final-message instruction above, and this project's hard rules so the reviewer does not fight them: no new dependencies (see *Dependency policy*), config is `AP_`-prefixed env vars only, errors are data not exceptions, ffmpeg args are argv lists never shell strings, and every option must round-trip to an identical cache key.

**Ask for a quoted snippet, not a line number — the line numbers are fabricated.** On `add-ready-endpoint` every citation the reviewer produced was invented: `readiness.ex:609-654` in a 139-line file, an API-doc row cited at line 89 that lives at 264. All eleven findings were nonetheless *substantively* correct and verified out, so this is a citation defect and not a hallucinated-findings problem — which is exactly what makes it expensive. The findings are worth having, and each one has to be relocated by hand before it can be checked. Requiring the reviewer to quote the offending line verbatim makes the finding self-locating (`grep` for it) and costs nothing. Do not soften the demand for evidence, only change its form: "quote the exact line and say what is wrong with it" replaces "cite `file:line`".

**A doc claim about what has *not* landed yet is a claim with an expiry date.** `docs/scaling.md` shipped saying `s3://` variant stores "arrive in their own slice"; that slice merged while the PR was open, and the sentence had to be corrected mid-rebase. Two consequences: when you write such a claim, phrase it so the surrounding paragraph survives the thing landing, and when you *implement* the slice, updating the documents that said it was pending is part of the change rather than a follow-up. Grep for the change's own name before archiving.

**Scope the brief's "deliberately absent" list explicitly** when reviewing one of a stack of PRs. Say what lands in the next slice and that reporting it is noise. Without it the reviewer spends its budget on the gap you already know about, and the findings you needed arrive as an afterthought — or not at all.

**After the run:** write your own self-review *before* reading the CLI output, then build a reconciliation table (Issue | Self-Review | CLI | Agreement), verify every CLI finding independently before accepting it, and present a synthesis with a gate status. **Never act on a finding without approval** — the CLI is a signal generator, not a judge. The working log is `second-opinion.md` (already gitignored); delete it once the findings are addressed. The improved code is the deliverable, not the log.

## Architecture decisions

- **Input side:** never pipe source bytes through the BEAM. Generate a presigned S3 URL and pass it to ffmpeg as an HTTP input — ffmpeg does its own Range requests, so `-ss` seeks and trims read only the bytes they need. Also avoids the stdin/MP4-moov-atom trap.
- **Output side:** ffmpeg writes encoded output progressively; only streamable containers by default (mp3, ADTS AAC, Ogg/Opus). MP4 family only as fragmented MP4 — cut on *duration*, `-movflags empty_moov+default_base_moof -frag_duration 1000000`. Not `frag_keyframe`: it cuts at video keyframes, so an audio-only stream gets a single fragment flushed at EOF (measured: first byte at 19.7 s of a 20 s source). Time-based fragments cost nothing measurable in size.
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
- **Slices are sized for review.** Target well under ~500 changed LOC per PR, tests included — the slices merged so far ran past 1000, which is too much to review confidently. When planning, prefer more, smaller changes split along module seams (contract vs. backends, mechanism vs. HTTP wiring, happy path vs. hardening). When implementing, a change heading past the target gets split or lands as stacked PRs rather than growing the diff.
- **Commits are atomic and follow [Conventional Commits](https://www.conventionalcommits.org).** One logical change per commit, each compiling with `mix test` green on its own — never a broken intermediate state that a later commit repairs. Scopes track the module or area touched (`feat(config):`, `feat(http):`, `build(devcontainer):`). Prefer a vertical slice (code plus its tests) over splitting code from the tests that cover it. Types in use: `feat`, `fix`, `refactor`, `perf`, `test`, `docs`, `build`, `ci`, `chore`.

## Open questions (decide as they come up)

- ~~Project/binary name~~ — settled for now: OTP app `audio_proxy`, still a working title. Renaming is a cheap find/replace while the project is small.
- ~~`ex_aws_s3` vs hand-rolled signing with `req`~~ — settled in `add-s3-client`: **`ex_aws_s3`**, plus `ex_aws` and `sweet_xml`. Three packages.

  Hand-rolled SigV4 was built first and worked — vectors, MinIO, the lot — and was still the wrong answer: ~2000 lines of signing, multipart orchestration and a fake S3 to test it against, all of it ours to maintain against a request contract AWS changes and we do not control. Volume was the deciding factor, not correctness.

  Two things the migration turned up, both worth knowing before anyone revisits this:

  - **`hackney` is deliberately absent.** `ex_aws` requires `hackney ~> 4.0` and ships an adapter for it, but that adapter cannot read hackney 4.0's bodyless responses (`{:ok, status, headers}`), so every `head/2` raises `CaseClauseError` from inside the dependency. An adapter had to be written either way, so it is `AudioProxy.S3.HttpClient` over OTP's `:httpc` — three new packages instead of twelve, and no QUIC/WebTransport stack in the image. Swapping back is a config key and one module.
  - **`ExAws.S3.upload/4` uploads one part per stream element and always uses multipart.** So it rejects small objects outright (`EntityTooSmall`), and needs the stream pre-grouped into 5 MiB parts. `AudioProxy.S3` does both: a single-`PutObject` fast path, and part-grouping above it.
- ~~Peaks output: exact JSON schema (audiowaveform compatibility?)~~ — settled in `add-peaks-format`: adopt [audiowaveform](https://github.com/bbc/audiowaveform)'s two formats outright, `version` 2 for both, so peaks.js reads the bytes as they come off the wire. Three consequences worth remembering rather than rediscovering. `bits` is always 16; the 8-bit mode would be a second cache key for a coarser picture. `f:peaks` is the one format whose `ch` default is mono rather than "follow the source" — the reducer needs the interleaving before it reads a byte, and a waveform UI draws one shape. And bucket boundaries are a function of the total sample count, so a peaks render is a *leading `ffprobe` and then* a decode. It shares `AudioProxy.Ffprobe`'s argv and contract mapping with `/info` — the duration the proxy *reports* and the duration it *buckets by* must not be able to drift — differing only in who runs the subprocess: `/info` blocks on `probe/2`, `Peaks.Render` spawns the same argv itself so it stays answerable to `cancel/1`. Buffering the whole decode instead would trade a header read for memory proportional to the source.
- Single-pass `loudnorm` accuracy — good enough for previews, revisit for masters.
- **Distro ffmpeg vs compiled from source.** Currently distro packages: both the devcontainer and the release image are `apt install ffmpeg` on debian trixie (7.1.5), so they now agree by construction. Building from source would buy an exact pinned version identical in dev and prod, and a `--disable-everything` codec set trimmed to what the API actually offers (smaller image, smaller attack surface). It costs a long build stage, a hand-maintained codec list, and the security-patch duty that distro packaging otherwise handles. Decide in `add-docker-release`; if the answer is yes, the devcontainer must build the same way or dev and prod diverge on codec behaviour.

  **`libfdk_aac` is off the table, and that removes a third of the case for building from source.** Debian and Alpine omit it on licensing grounds, and those grounds are decisive rather than cautious: the Fraunhofer FDK AAC licence is incompatible with (L)GPL, ffmpeg therefore requires `--enable-nonfree` to include it, and a `--enable-nonfree` binary **may not be redistributed at all**. Building it in means the release image cannot be published. The command builder already emits ffmpeg's native `aac` encoder, so the safe path is the current one; reaching for `libfdk_aac` would have to be a deliberate choice to ship no image.
- **AAC patents.** Unlike MP3 — whose patents expired and whose licensing programme Fraunhofer/Technicolor terminated in April 2017, which is why `libmp3lame` (LGPL, and so not GPL-forcing) ships in stock distro ffmpeg — AAC is still patent-encumbered via the Via LA pool. For a proxy transcoding a catalogue the operator already holds rights to this is widely treated as low practical risk, but `f:aac` and `f:m4a` should be offered as a conscious decision rather than an accident. The unencumbered set, if a build ever needs one, is Opus (royalty-free by design), Vorbis, FLAC and WAV. Not legal advice; worth a real opinion before anything commercial.
- HLS (v2): URL space is reserved, nothing else designed.
