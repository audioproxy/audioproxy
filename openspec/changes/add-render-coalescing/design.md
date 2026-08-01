## Context

The classic single-flight problem, solved with OTP primitives per CLAUDE.md: `Registry` (unique keys) + a coordinator GenServer per in-flight key.

## Goals / Non-Goals

**Goals:**
- Race-free single-flight; byte-exact catch-up; clean teardown in every subscriber/render permutation.

**Non-Goals:**
- Cross-node coalescing (single node); persisting partials beyond the render's lifetime (that's the variant cache); HTTP concerns.
- Concurrency limiting — `add-render-semaphore` (post-MVP) adds acquire-before-spawn/release-on-terminate to this coordinator; until then the coordinator spawns its pipeline directly.

## Decisions

- **Start race via `Registry.register`-style uniqueness**: subscriber calls `DynamicSupervisor.start_child`; `{:error, {:already_started, pid}}` → join that pid. Losing the race is the COALESCED path.
- **The coordinator is where the semaphore slot will live** (acquired before spawning the pipeline, released on terminate — slot lifetime equals subprocess lifetime, and queue waiting happens before dedup'd work starts). Deferred to `add-render-semaphore`; the seam is the coordinator's spawn/terminate pair, which this slice keeps in one place so the later diff is small.
- **Backlog as an in-memory iodata list** (preview-sized outputs; bytes retained anyway for the S3 tee). Join protocol: `subscribe` is a `call` returning `{status, backlog}` atomically with subscriber registration — the seam cannot drop or duplicate a chunk because both happen in one coordinator callback.
- **Broadcast as plain `send/2`** to monitored subscriber pids with the same message contract the pipeline uses — the HTTP layer consumes either directly.
- **Terminate states**: `:done` → broadcast, linger briefly (`:completed` state) for stragglers already past HIT-check, then stop; error → broadcast, unregister immediately (retry allowed); last-subscriber DOWN → cancel pipeline, stop.
- **Memory bound**: backlog capped by `AP_MAX_SRC_BYTES`-derived output ceiling; exceeding it fails the render (protects against unbounded full-length transcodes until the FIFO escalation).

## Risks / Trade-offs

- [In-memory backlog caps variant size] → explicit and configured; fine for the preview-centric v1 target, revisit with FIFO/disk spool escalation.
- [Linger window after done vs. Registry cleanup] → bounded (~1 s) and tested; stragglers landing after unregister just start a fresh render — correct, only wasteful.
- [No concurrency cap until the semaphore lands] → the MVP is demo/integration-grade by declaration; coalescing itself already bounds the worst hot-key case (N requests for one variant = 1 ffmpeg), leaving only distinct-key bursts uncapped.
