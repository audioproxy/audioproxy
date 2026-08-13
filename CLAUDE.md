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

**Stage those two by path, never with `git add -A`.** Both are commits whose contents another tool wrote, so there is nothing in them you are checking line by line — which is exactly when a stray working-directory file rides along unnoticed. Twice it was `.playwright-mcp/`, the console logs and page snapshots the browser-automation server drops in the repo root: swept into `8d2e4bb` and again into `342ca89`, from the same step, by the same `-A`. `git add openspec/` (or the specific paths a merge resolved) costs one extra word and cannot do that. The `.gitignore` now covers that particular directory; the habit is what covers the next one.

Workflow mechanics (devcontainer, ports, hooks) are under *Dev workflow* below.

## Stack — decided, don't relitigate

- **Elixir**, Plug + **Bandit** (no Phoenix — no HTML, no channels needed)
- **ffmpeg via subprocess** (Port), not libav bindings. ffmpeg does all decoding/encoding; the Elixir side is orchestration only. This is also the licensing posture: the (L)GPL boundary is a *process* boundary, so `audio_proxy` is a distinct program invoking a CLI and even a GPL-configured ffmpeg imposes nothing on this source tree. A future proposal to switch to NIF-based libav bindings "for performance" therefore changes the licensing analysis too, and has to be argued on both. **The published image is a separate matter and complies on its own terms**: Debian's `/usr/share/doc/*/copyright` notices plus `/usr/share/audioproxy/SOURCES.txt`, a build-time manifest pinning every installed package to its exact source on snapshot.debian.org, both asserted by the `license-compliance` CI job. Any image-slimming pass must preserve `/usr/share/doc` and that manifest; the job is what stops a size optimization from quietly breaking the GPL.
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
  | `llms.txt`, `llms-full.txt` | The API contract as one self-contained markdown file, at the repo root per the llms.txt convention and carried in the hex package. | Would someone with *only* this file still build the URL correctly? |

  **The llms files carry the same obligation the README does, and part of it is enforced.** Any slice that changes the API surface — an option, an error code, an endpoint, a config variable, the signing rule — updates `llms-full.txt` in the same change. Three tables there are compared against the implementation by `test/llms_docs_test.exs` — options against `AudioProxy.Options.keys/0`, errors against `AudioProxy.ErrorJSON.rows/0`, configuration against `AudioProxy.Config.variables/0` — and the worked signing example is recomputed from `AudioProxy.Signature.sign/3`, so those four cannot drift silently. The README's configuration table is checked against `variables/0` by the same rule, in `test/readme_examples_test.exs`: it is the same list written twice, and both copies now have to agree with the code.

  Two of those guards need something kept up, and both have a test of their own for it. `ErrorJSON.rows/0` derives its table from `@representative_errors`, so a new `render/1` clause reaches the guard only once it is listed there — `AudioProxy.ErrorJSONTest` counts the clauses to make sure it is. `Config.variables/0` is a hand-written list beside the reads it describes, so `AudioProxy.ConfigTest` scans `config.ex` for `(env, "AP_…")` call sites and fails when the list and the reads disagree in either direction.

  **The configuration guard covers variable *names*, not defaults.** A default that moves — `AP_QUEUE_SIZE` from `32`, `AP_PRESIGN_TTL` from `300` — still ships wrong if nobody edits the table; only a variable arriving or leaving fails CI. That was the deliberate call: several defaults are derived rather than literal, and the README and `llms-full.txt` word those differently for different readers, so comparing them would mean both quoting one rendered string. The `AWS_*` credentials variables are outside the guard too, described in prose beside each table.

  Everything else in the file is unguarded: the endpoint list, the response semantics, the cross-key rules. Treat the guards as covering the part that is easiest to forget, not as covering the file.

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
    "bash": { "*": "allow" },
    "glob": "allow", "grep": "allow", "read": "allow",
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

**The config block above is version-specific, and on opencode 1.17.11 it is what breaks the run.** There, *any* `permission` key in `OPENCODE_CONFIG` hangs at `message=init` with a 0-byte output file — the full block, and a deny-only `{"edit": "deny", "write": "deny", "patch": "deny"}` subset alike, with no `evaluated permission` line ever logged. 1.17.11 allows `bash`/`read`/`grep`/`glob`/`external_directory` by default (the session log shows only `question`/`plan_enter`/`plan_exit` denied), so the working invocation there is **no `OPENCODE_CONFIG` at all**. Check `opencode --version` before reaching for the block, and diagnose with the ladder below rather than by assuming which failure you have: on `extract-test-fixtures` the tool-using smoke test hung, the tool-less one returned `OK` in seconds, and the *same* tool-using prompt with no config file succeeded and logged `action.action=allow`. That third step is what localises it to the config rather than to the permission model.

The cost is real and worth stating: without the override there is no no-write guarantee, only the after-the-fact one. Commit first, keep "do not edit any files" in the brief, and let `git status --short` on the committed tree be the proof.

- **Model:** `opencode-go/kimi-k2.7-code`. First-party ids are flat; OpenRouter's need the vendor path (`openrouter/moonshotai/kimi-k2.7-code`, never `openrouter/kimi-k2.7-code`, which fails slowly and silently). Prefer a first-party route where one exists — an aggregator that degrades presents as an unexplained hang, and swapping the route is a one-flag way to rule that out. Fallbacks: `openrouter/deepseek-v4-pro`, `openai/gpt-5.6-pro`.
- **`--print-logs` on every run.** It puts structured logs on stderr and leaves the answer on stdout, which is the only way to tell a working run from a hung one — both are a 0-byte output file otherwise. Poll `review.err` and watch `message=loop step=N` advance. It is a diagnostic, not a fix: a run that seems to start working when you add it was working already.
- **Override the tool permissions for the run.** If opencode's user config denies `bash`/`glob`/`grep`/`read` — a reasonable thing to do when MCP equivalents are preferred — `opencode run` hangs forever at `message=init` with a 0-byte output file, because a review needs to read the code and has no way to. Override per-run via `OPENCODE_CONFIG` as above; **never edit the user's own config.** Denying `edit`/`write`/`patch` in that same override is also the only no-write guarantee opencode has, since no flag provides one.
- **`bash` takes the object form, and the string form is silently ignored.** `"bash": "allow"` parses, loads without complaint, and then hangs at `message=init` exactly as a denial does — the config block above is written `"bash": { "*": "allow" }` for that reason, and it is not stylistic. The other permissions (`read`, `grep`, `glob`, `external_directory`) do take a bare string. Tell a working config from an ignored one by the log rather than by the config: a run that is going to work prints `evaluated permission=bash pattern="…" action.action=allow` within a step or two of `message=loop step=0`. No such line means the permission never applied.
- **`external_directory` must be allowed too, and its absence is a *third* failure mode.** Left out, the run dies mid-review with `Error: The user rejected permission to use this specific tool call.` — because a permission whose verdict is `ask` cannot be asked non-interactively, so it is refused, and the refusal aborts the whole run rather than just that call. The reviewer earns it honestly: it redirects `git diff main...HEAD` to a file under `/tmp` and then tries to read it back, which is a read outside the project directory. Tell it apart from the other two by the log — `evaluated permission=external_directory ... action.action=ask` followed by `message=asking`, at a step count well past init, with an exit rather than a hang. Bash is what wrote the file, so this permission is not a write hole: `edit`/`write`/`patch` stay denied and the post-run `git status --short` still proves nothing in the repo moved.
- **Smoke-test with a prompt that uses a tool** (`"Run 'git rev-parse --abbrev-ref HEAD' and reply BRANCH=<name>"`). A tool-less "reply OK" prompt passes under a config that makes review impossible, and has burned a whole session that way. It will not catch the `external_directory` case above, which needs a *review-shaped* prompt to surface — so a green smoke test means the model can read code, not that the run will finish.

  When the tool-using smoke test *does* hang, the tool-less prompt stops being a trap and becomes the diagnostic: run `"Reply with exactly: OK"` next. `OK` back in a couple of seconds proves the provider, the credentials and init are all fine and puts the fault squarely on the tool permission — which is a much shorter list to work through than "something is wrong with opencode". A hang on both means the problem is upstream of the review.
- **Commit before running** so `git status --short` afterwards proves the reviewer mutated nothing.
- Runs take 5–20 minutes and are I/O-bound. A stalled byte count plus a live process is normal mid-thought.

**A third failure is the provider rejecting its own conversation, and it is neither of the two below.** On `guard-config-documentation` two runs died mid-review with a non-zero exit and this on stderr:

```
Error from provider (Console Go): Upstream request failed: [invalid_request_error]
Invalid request: the message at position 22 with role 'assistant' must not be empty
```

Position 22 on `opencode-go/kimi-k2.7-code` at loop step 10, position 33 on `opencode-go/kimi-k3` at step 13 — **two models on the same route**, so this is the route's accumulated-conversation validation, not a model quirk, and swapping the model does not dodge it. The trigger is an assistant turn that produced reasoning and a tool call but no text part, which the route then replays as an empty message. It is time-dependent: the longer the review runs, the likelier a reasoning-only turn is in the history. Tell it from the other two by exit status and the stderr line — it is the only one of the three that names an error at all.

Two consequences. **Recovery is the same SQLite dig** as the empty-output case below, and it works: 72 KB of reasoning off the second run held a consolidated, severity-rated finding list that reconciled cleanly and turned up four real defects. And **`opencode/…` is not a drop-in fallback for `opencode-go/…`** — the first-party route answered `Insufficient balance` in under a second, which at least fails fast and unambiguously.

**Adding "emit findings as you go" to the brief does not solve this, and the logs will suggest it did.** Run three wrote eight narrator lines to stdout — "Suite is green (119 passed). Now let me empirically probe the scan regex…" — so the byte count grew, the run looked healthy, and every actual finding was still stranded in reasoning when the provider killed it. Progress narration is not findings. Judge a run by whether a *severity-rated finding* has reached stdout, never by the file being non-empty.

**A clean exit with an empty output file is a distinct failure — do not confuse it with the hang above.** A reasoning model can spend its entire final turn thinking and never emit a text part: exit 0, a full log ending in `exiting loop`, several completed steps, and nothing to print. Observed at 131,000 characters of reasoning, much of it degenerating into repetition, with no answer at the end. The two failures share the 0-byte symptom and nothing else — tell them apart by exit status and log tail, never by the size of the output file. Two consequences:

- **The brief must demand the findings as the final message** — "think briefly, then write; if you are running long, write what you have." Keep carrying it: three consecutive runs once returned nothing, and the first run carrying that instruction returned a review that found a real bug. **It is not the reliable prevention this file used to claim, though.** On `bound-probe-concurrency` the failure recurred with the instruction present and prominent — 19 loop steps, clean exit, 71 bytes of stdout holding only "I'll read the branch, run the tests, and write the review", and the whole review stranded in 105,000 characters of reasoning. So treat the instruction as improving the odds and the recovery below as the thing you actually rely on. An answer arriving all at once at the end is still what success looks like, not a symptom. It recurred again on `extract-test-fixtures` — 7 steps, 6 tool calls, clean exit, **0 bytes**, 21,646 characters of reasoning holding a complete audit. Two recurrences now, so plan the recovery into the schedule rather than treating it as the exception.
- **Recover rather than re-run.** Recent opencode keeps sessions in a SQLite database under its data directory (`~/.local/share/opencode/opencode.db`); copy it, `-wal` and `-shm` included, rather than reading the live one. The schema is JSON-in-a-column, not typed columns, so the queries are:

  ```bash
  sqlite3 oc.db "select json_extract(data,'\$.type'), count(*) from part
                 where session_id='ses_…' group by 1;"        # what is there
  sqlite3 oc.db "select json_extract(data,'\$.text') from part
                 where session_id='ses_…'
                   and json_extract(data,'\$.type')='reasoning'
                 order by time_created;" > reasoning.txt
  ```

  Then `grep -nE "Severity|\*\*H\*\*|\*\*M\*\*|\*\*L\*\*" reasoning.txt`. Reasoning models tend to consolidate near the end, so the last such block is usually the real list. Note that a `text` part is not proof of an answer: the prompt is echoed as one, so check the count — two text parts where one is the brief means the review never became text. Treat what comes back as findings, not as a review; it never went through whatever produces the final answer, so it carries lines of thought the model later abandoned.

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

## Test support

`test/support/` is where anything more than one test file needs lives. Before
writing a helper in a test file, look here — the suite has repeatedly grown its
tenth copy of something that already existed.

The shared modules, and what a test file is therefore not allowed to write for
itself:

| Module | Owns | The rule |
|---|---|---|
| `AudioProxy.ConfigHelper` | Installing config for a test, and the byte-limit floor. | The limits are taken from `byte_limits/1`, never written as literals. |
| `AudioProxy.SignedRequest` | Signing key material, the config floor, the URL grammar, conn builders. | An endpoint test starts from `base_config/1`. |
| `AudioProxy.Eventually` | Waiting for a condition that nothing announces. | A poll loop is imported, never written. |
| `AudioProxy.Fixtures` | Generated audio fixtures, and the fixture root they live in. | A fixture path is never a fixed name under `System.tmp_dir!()`. |
| `AudioProxy.TestServer` | Booting a real listener, and reading back the port it got. | A test that binds a socket boots it through this helper. |
| `AudioProxy.MarkedTable` | Reading a table out of a marked region of a published document. | A drift guard parses its table through this, never with its own regex. |

Promoting another duplicated helper adds a row here and a subsection below. The
section is meant to grow a row at a time; nothing above needs rewriting to make
room.

`AudioProxy.ConfigHelper` owns config installation and the floor's lower layer:

| Function | Holds |
|---|---|
| `put_config/1` | Merges overrides into the stored config and restores them on exit. Global state, hence `async: false`. |
| `byte_limits/1` | The two byte limits, with the caller's overrides merged over them. Requires nothing. Carries the reason the floor exists. |
| `validate_keys!/2` | The known-key set, derived from `AudioProxy.Config.build!(%{})`. Called by `put_config/1` and `base_config/1`, not usually by a test. |

**Which floor a file reaches for is decided by whether it signs.** A test that
signs a URL or resolves a `local://` source takes `SignedRequest.base_config/1`;
a test that only needs the environment kept away from its size limits takes
`byte_limits/1` and neither imports a signing helper nor invents a `local_root`
it has no use for. `base_config/1` is built on `byte_limits/1`, so the numbers
have one definition and the dependency runs one way: config is the lower layer.

`AudioProxy.SignedRequest` owns the signing preamble every endpoint test shares:

| Function | Holds |
|---|---|
| `key/0`, `salt/0` | The suite's signing key material. **Fixed test vectors, not secrets** — never loaded by `lib/`, never an operational default. |
| `base_config/1` | The config floor, with the caller's overrides merged over it. Requires `local_root`. Carries the reason the floor exists. |
| `signed/1` | A request remainder to a signed path, per API doc §2. Deliberately an independent implementation of the grammar, so a divergence from `lib/` fails a test. |
| `conn/3` | A `Plug.Test` conn with request headers folded in. Call it qualified; a file importing `Plug.Test` too imports this module `except: [conn: 3]`. |
| `header/2` | The first response header, or `nil`. |

Three rules that are easy to get wrong:

- **A new endpoint test starts from `base_config/1`, not a fresh literal map.**
  The floor pins every config value the request chain reads so that an
  `AP_MAX_SRC_BYTES` in a developer's shell cannot flip a 501 assertion into a
  413 failure. A file that writes its own map opts out of that silently.
- **A value the test is *about* goes in the overrides, where a reader sees it.**
  `base_config(local_root: tmp_dir, probe_timeout: 1)` reads as floor-plus-subject.
  Never bury a test's subject inside the floor, and never widen the floor to
  accommodate one file.
- **A mistyped override is refused, not merged.** `probe_timout: 1` used to
  install a key nothing reads and leave `probe_timeout` at whatever the
  environment gave it — the same class of failure the floor exists to prevent,
  one layer in. Both `base_config/1` and `put_config/1` now raise, naming every
  unknown key — with the nearest match where jaro finds one, and with
  `s3: %{…}` where the key is real but written a level too high. The set comes
  from `AudioProxy.Config.build!(%{})`, including the `:s3` group — in map or
  keyword form, since a keyword `:s3` is how the typo got through once — so
  a new config setting is overridable the moment `lib/` defines it and no
  support-layer edit is owed. A rejection is a finding: the key names something
  nothing reads.

`put_config/1` stays an explicit call in each file's `setup`: it writes global
state, which is what makes `async: false` mandatory, and hiding it would make
that requirement invisible.

`AudioProxy.Eventually` owns polling. Reach for `assert_receive` first — it
covers everything that sends a message when it happens — and for the rest:

| Function | Holds |
|---|---|
| `wait_until/2` | Polls, flunks on expiry, naming the deadline it exceeded. For a precondition. |
| `eventually?/2` | Polls, returns a boolean. For a wait that *is* the assertion, including `refute`. |
| `wait_for/2` | Polls a condition returning `{:ok, value}` or `{:retry, observed}`, returns the value, flunks on expiry naming the deadline it exceeded and the last `observed`. For a wait whose result is the value, where re-reading after a boolean wait would reopen the race. |
| `gone_within?/2`, `alive?/1` | The OS-process pair, via `kill -0`. `gone_within?/2` is `eventually?/2` over `not alive?/1`. |

Two rules, for the two things seventeen local copies disagreed about:

- **The poll loop is imported, not written.** Seventeen authors needing a wait
  produced seventeen loops, under four names, at five different intervals with
  three different failure messages, none of them chosen. The interval lives in
  the module and nowhere else; a caller that genuinely needs its own gets an
  option added there rather than a private `defp`. The three waits are the
  three things a caller can want back — a verdict, a boolean, a value — so the
  rule has no exceptions to plead: `grep -rn "defp await\|defp wait_\|defp
  eventually" test` returns nothing, and a fourth shape would be an argument
  for a fourth function here rather than for a local loop.
- **The deadline stays at the call site.** It is the one part that legitimately
  varies — 2 s to 10 s, for real reasons — so a file whose budget is not the
  module's 5 s default passes `@deadline` explicitly, where the test is read.
  Budget a wait whose condition is a *request* in conditions rather than in
  milliseconds: the deadline is checked between evaluations, never during one.

`AudioProxy.Fixtures` owns generated audio, for the five `:ffmpeg`-tagged files
that need real bytes:

| Function | Holds |
|---|---|
| `root!/1` | A labelled fixture root, unique per run, `rm_rf` on exit. The only way to get one. |
| `encode!/3` | The `lavfi` generation argv: source expression in, output options in, path out. |
| `tone/2`, `sine/2` | The two sine generators. `tone/2` is `lavfi`'s bare `sine`; `sine/2` takes an amplitude. |
| `silence/2`, `video/1`, `tagged_mp3/2` | The named fixtures more than one file wants. |

Two rules, and the first of them is a bug fix rather than a tidy-up:

- **A generated fixture path is never a fixed name under `System.tmp_dir!()`.**
  Worktree isolation covers the directory and the port; it does not cover the
  system temp dir, which every parallel checkout shares. Two files named fixed
  paths there, and two concurrent `mix test --only ffmpeg` runs duly deleted
  each other's fixtures mid-render — a failure in a test with nothing wrong
  with it. `root!/1` appends `unique_integer/1` with no opt-out, because the
  opt-out is what broke.
- **A file written in order to be probed is an output, and goes in the test's
  own `:tmp_dir`.** Never beside the module's fixtures: an output two runs
  collide on is the one under assertion.

What each file generates stays in that file's `setup_all` — the fixture *list*
is the file's subject, and a value the test is about (duration, amplitude, rate,
codec) is named at the call site. Only the argv is shared.

`AudioProxy.TestServer` owns listener boot, for the nine files that need a real
socket rather than a `Plug.Test` conn:

| Function | Holds |
|---|---|
| `start!/2` | Bandit under `start_supervised!` on an ephemeral loopback port, returning `%{port: port, server: pid}`. Extra Bandit options merge over the defaults; `:id` defaults to `{TestServer, plug}`, so a file booting two listeners on different plugs does not collide. Same plug twice still needs its own `:id`. |

Two rules, and both are about what the helper deliberately does *not* take
over:

- **The plug is named at the call site, never defaulted.** Three files boot the
  production `AudioProxy.Router`, four boot `AudioProxy.FakeFfmpeg.Router`, and
  the rest boot a plug written for the one test that mounts it — and that
  argument is the whole subject of each of those files.
  `TestServer.start!(FakeFfmpeg.Router)` has to say as much as the five lines it
  replaced.
- **`put_config/1` stays in the test, before the boot.** The plug chain reads
  config per request, but `AP_LOCAL_ROOT` has to be right before the first
  request arrives, and every file's config differs. Folding it in would couple
  two things that vary independently.

The one line here a dependency upgrade can break is
`ThousandIsland.listener_info/1`, reached through Bandit's supervisor pid. It
now breaks in one place: a `MatchError` from this module means Bandit or
Thousand Island changed how a bound port is reported, not that the calling test
is wrong. The `{127, 0, 0, 1}` on both sides of that match is an assertion that
the listener came up loopback-only, not leftover pattern.

`AudioProxy.MarkedTable` owns the parser the documentation drift guards share,
for the tables fenced by `<!-- <name>-table:start -->` in `llms-full.txt` and
`README.md`:

| Function | Holds |
|---|---|
| `rows/2` | The rows of a marked table, each as its list of backticked cell tokens. A non-backticked cell is `nil`; a row whose *first* cell is not backticked is dropped, which is what skips the header and the `\|---\|` separator. |
| `first_cells/2` | Just the first cell of each row — the key, the code, the variable name. What a coverage guard almost always wants. |

One rule, and it was bought rather than reasoned:

- **A guard parses its table through this module, never with its own regex.**
  The README's configuration guard shipped with a hand-rolled copy of the
  parser that already existed in `llms_docs_test.exs`, and the copy was not
  equivalent: on a line holding nothing but `|` the original returned no row and
  the copy raised `ArgumentError` from `hd([])`. Two parsers, one document
  format, one of them wrong — found by an adversarial review within a day of
  the copy being written. A missing marker still raises `MatchError` on purpose:
  a guard that silently parsed an empty region would pass while checking
  nothing.

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
