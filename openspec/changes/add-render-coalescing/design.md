## Context

The classic single-flight problem, solved with OTP primitives per CLAUDE.md: `Registry` (unique keys) + a coordinator GenServer per in-flight key.

## Goals / Non-Goals

**Goals:**
- Race-free single-flight; byte-exact catch-up; clean teardown in every subscriber/render permutation.

**Non-Goals:**
- Cross-node coalescing (single node); persisting partials beyond the render's lifetime (that's the variant cache); HTTP concerns.

## Decisions

- **Start race via `Registry.register`-style uniqueness**: subscriber calls `DynamicSupervisor.start_child`; `{:error, {:already_started, pid}}` → join that pid. Losing the race is the COALESCED path.
- **Coordinator holds the semaphore slot** (acquired before spawning the pipeline, released on terminate) — slot lifetime equals subprocess lifetime, and queue waiting happens before dedup'd work starts.
- **Backlog as an in-memory iodata list** (preview-sized outputs; bytes retained anyway for the S3 tee). Join protocol: `subscribe` is a `call` returning `{status, backlog}` atomically with subscriber registration — the seam cannot drop or duplicate a chunk because both happen in one coordinator callback.
- **Broadcast as plain `send/2`** to monitored subscriber pids with the same message contract the pipeline uses — the HTTP layer consumes either directly.
- **Terminate states**: `:done` → broadcast, linger briefly (`:completed` state) for stragglers already past HIT-check, then stop; error → broadcast, unregister immediately (retry allowed); last-subscriber DOWN → cancel pipeline, stop.
- **Memory bound**: backlog capped by `AP_MAX_SRC_BYTES`-derived output ceiling; exceeding it fails the render (protects against unbounded full-length transcodes until the FIFO escalation).

## Risks / Trade-offs

- [In-memory backlog caps variant size] → explicit and configured; fine for the preview-centric v1 target, revisit with FIFO/disk spool escalation.
- [Linger window after done vs. Registry cleanup] → bounded (~1 s) and tested; stragglers landing after unregister just start a fresh render — correct, only wasteful.
