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

## Risks / Trade-offs

- [GenServer as bottleneck] → operations are O(1) message sends at ffmpeg-process cadence (a few per second at most, per box) — nowhere near mailbox limits.
- [Caller-timeout vs server-grant race (grant lands after caller gave up)] → waiter monitor catches the caller's exit; also handle late `:granted` messages idempotently in the client API.
