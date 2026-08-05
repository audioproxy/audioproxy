## Context

Two subprocess pools exist now, and only one is rationed. `AudioProxy.Semaphore` caps encoders at `AP_MAX_CONCURRENCY` with a bounded FIFO behind it; probes have no cap at all, by a decision that was correct when `/info` was their only caller and is merely inherited now that every render MISS probes first.

The order on the render path is: 304 → cache lookup → stat → **probe** → semaphore → coalescing registry → render. The probe sits ahead of both mechanisms that bound work, and it has to: a refused source must not hold a slot, and it must not join a render it will never need.

## Goals / Non-Goals

**Goals:**
- Concurrent requests for one cache key cost one probe, not one each.
- A ceiling on concurrent probes that an operator chose, rather than "however many connections Bandit accepted".
- Keep the property that made the probe path fast: a probe must not queue behind an encoder.

**Non-Goals:**
- Moving the probe under `AP_MAX_CONCURRENCY`. That is the one thing this must not do — see *Decisions*.
- Caching probe verdicts across requests. Possibly right, deliberately out of scope until the measurements say the in-flight sharing was not enough.
- Revisiting the gate's placement. It is after the cache lookup and before the semaphore for reasons `add-audio-only-policy` argued; this change makes that placement affordable, not different.

## Decisions

- **Measure first, and write the numbers down.** Probe cost (spawn + header read + teardown) for a local file and an HTTP source, and the concurrency at which a box degrades — scheduler time, file descriptors, or process table. Without them, "bound probes" is a number pulled from the air, and this project has a habit of measuring things like this (`Path.safe_relative/2`'s component cap, `-frag_duration`'s fragment count) rather than asserting them.
- **Coalescing before capping.** If N requests for one key collapse to one probe, the pathological case mostly evaporates and a cap becomes a backstop rather than the mechanism. It is also the cheaper change: `Registry` plus a broadcast is a pattern already in the codebase.
- **A separate counter, never the render semaphore.** They ration different resources: a slot means "a core is pinned for the length of a file", a probe means "a header read is in flight". Sharing one cap would put probes behind encoders, which is exactly what `AudioProxy.Ffprobe`'s moduledoc says must not happen — it would make `/info`, the endpoint a client calls *before* it knows what to ask for, the slowest thing in the proxy.
- **Overflow is 429 with `Retry-After`**, reusing what the semaphore already produces and `AudioProxy.ErrorJSON` already renders. No new status, and the same client contract: come back, the box is busy.
- **A refused source is the interesting case.** Video sources never reach the semaphore, so the queue never sheds them. If the measurements show probes are the cheap way to burn CPU, the bound has to sit ahead of the gate to help at all — which means the bound is on *probes*, not on renders that follow them.

## Risks / Trade-offs

- [A probe bound adds a queue in front of the cheapest part of the request] → keep the bound high relative to `AP_MAX_CONCURRENCY`; the point is a ceiling, not scheduling.
- [Coalescing probes couples two request paths that currently share nothing before the render] → the coordinator already monitors subscribers and cleans up on crash; reuse that discipline rather than a second lifecycle.
- [Sharing a probe result means sharing a *stale* one if a source changes mid-flight] → the window is one probe's lifetime, and the render that follows reads the same bytes the probe did. Not worse than the status quo, where each request probes and then renders separately.
- [Measurement may say the whole thing is unnecessary] → then this change closes with the numbers in the archive, which is a better outcome than the code.
