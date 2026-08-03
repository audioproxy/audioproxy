## Context

Classic counting semaphore; the only subtlety is crash-safety in both directions (holders and waiters) and not blocking the GenServer itself.

## Goals / Non-Goals

**Goals:**
- Correctness under races and crashes; observability hooks.

**Non-Goals:**
- Per-key fairness or priorities; distributed limiting (single node by design).

## Decisions

- **Single GenServer, non-blocking loop**: `acquire` is `GenServer.call` with the *caller's* timeout; the server replies `:granted` immediately or parks the `from` ref in a queue — the server never blocks. Grants happen in `release`/`DOWN` handling.
- **`Process.monitor` on every holder and waiter**; `DOWN` of a holder releases, `DOWN` of a waiter drops it from the queue. No linked-process gymnastics.
- **Queue as `:queue`** with a size counter (O(1) overflow check).
- **`Retry-After` hint** derived from a moving average of recent render durations (kept in the semaphore state) — coarse is fine; spec only requires the header exists.
- **Telemetry**: `[:audio_proxy, :semaphore, :acquired | :released | :queued | :rejected]` with occupancy/depth measurements.

## What shipped differently

Kept as amendments rather than edits above, so the record still shows what was
decided before the code existed.

- **Five telemetry events, not four.** `:abandoned` was added for a waiter that
  leaves the queue before its turn. Without it a queue draining by attrition —
  clients giving up — leaves the depth gauge reading high until some unrelated
  event corrects it.
- **A slot is released when the render finishes**, not when the process holding
  it stops. The two are not the same moment: a completed coordinator lingers
  briefly to serve late subscribers from memory, and a slot held across that
  costs `linger / (duration + linger)` of the cap — most of it, for the
  preview-sized renders v1 targets.
- **A queued request that runs out of budget is a 429**, not the 504 the
  unmodified receive deadline produced. The queue could not reach it; no render
  ran to time out.

## Risks / Trade-offs

- [GenServer as bottleneck] → operations are O(1) message sends at ffmpeg-process cadence (a few per second at most, per box) — nowhere near mailbox limits.
- [Caller-timeout vs server-grant race (grant lands after caller gave up)] → waiter monitor catches the caller's exit; also handle late `:granted` messages idempotently in the client API.
