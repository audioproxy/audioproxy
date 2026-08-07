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
- **The coalescing identity is the source, not the cache key.** Decided during
  implementation, against what this change's own delta spec first said, and the
  spec was corrected rather than the code. Two reasons, in order of weight.
  Task 2.4 requires `/info` to share the mechanism, and `/info` describes no
  variant — there is no cache key for it to be identified by, so a cache-key
  identity would have meant either a second mechanism or an endpoint-shaped
  exception. And a probe's verdict depends on the source alone: `f:mp3/br:128`
  and `f:opus` of one file ask ffprobe the identical question about the
  identical bytes, so the variant identity would have been strictly narrower for
  no benefit. Every scenario the original requirement listed still holds, since
  source-keying is a superset of variant-keying.
- **Coalescing before capping.** If N requests for one key collapse to one probe, the pathological case mostly evaporates and a cap becomes a backstop rather than the mechanism. It is also the cheaper change: `Registry` plus a broadcast is a pattern already in the codebase.
- **A separate counter, never the render semaphore.** They ration different resources: a slot means "a core is pinned for the length of a file", a probe means "a header read is in flight". Sharing one cap would put probes behind encoders, which is exactly what `AudioProxy.Ffprobe`'s moduledoc says must not happen — it would make `/info`, the endpoint a client calls *before* it knows what to ask for, the slowest thing in the proxy.
- **Overflow is 429 with `Retry-After`**, reusing what the semaphore already produces and `AudioProxy.ErrorJSON` already renders. No new status, and the same client contract: come back, the box is busy.
- **A refused source is the interesting case.** Video sources never reach the semaphore, so the queue never sheds them. If the measurements show probes are the cheap way to burn CPU, the bound has to sit ahead of the gate to help at all — which means the bound is on *probes*, not on renders that follow them.

## What a probe costs — measured

`bin/measure-probe-cost`, against the runtime image's ffprobe 7.1.5 on
linux/arm64, 10 cores. Regenerate rather than trust these if the image's ffmpeg
moves.

| Source | Median | p95 | Max |
|---|---|---|---|
| local | 47 ms | 56 ms | 68 ms |
| http | 43 ms | 44 ms | 49 ms |

One probe at a time, 20 runs per arm. The HTTP arm is nginx one docker network
away, so its latency is a *floor* rather than a real endpoint's — a presigned S3
URL adds a real RTT and a TLS handshake on top. What the two rows landing within
a few milliseconds of each other says is that a probe is not dominated by the network
even when the network is free: it is dominated by starting ffprobe.

| In flight | Median | Max | Burst | Peak procs | Peak fds |
|---|---|---|---|---|---|
| 1 | 78 ms | 78 ms | 80 ms | 6 | 24 |
| 8 | 95 ms | 97 ms | 98 ms | 20 | 81 |
| 32 | 254 ms | 286 ms | 290 ms | 68 | 272 |
| 128 | 1171 ms | 1281 ms | 1295 ms | 260 | 1078 |
| 512 | 6052 ms | 7542 ms | 7634 ms | 698 | 1562 |

**What binds first is the CPU, and nothing else comes close.** At 512 probes in
flight the container held 1562 file descriptors against a limit of 20480 and 698
processes against 24089 — neither within an order of magnitude of running out.
Meanwhile per-probe latency went from 78 ms to 6 s, and throughput peaked at
roughly 110 probes/second around 32 in flight and *fell* to 67/second at 512.
That is the signature of a workload contending for the CPU past saturation, not
of a resource being exhausted.

**A probe is ~45 ms of wall clock, and only part of that is core time.** Worth
stating precisely, because the numbers do not support the stronger claim: a
purely CPU-bound 45 ms unit on 10 cores would scale to roughly 220
probes/second, and the measured peak is 110. So something under half of a probe
is core occupancy — dynamic linking against libav and codec-table
initialisation, mostly — and the rest is serialized I/O that a core is not held
for. The instrument here measures wall clock; it cannot separate the two, and
this section should not pretend otherwise.

The conclusion is unchanged, and does not need the stronger claim: descriptors
and processes are each more than an order of magnitude from their limits at
every level measured, so whatever fraction of a probe is CPU, the CPU is what
degrades first. The knee sits at the core count, which is what a
partly-CPU-bound cost predicts. Below it latency is flat and throughput scales;
above it latency grows linearly with depth and throughput slowly degrades.

## The decision task 1.3 asks for: ship the bound

**Yes, §3 is still needed once §2 lands**, and the measurements say why in one
line: coalescing is keyed on the *variant*, and the pathological case is not.

Coalescing removes duplicate probes for one cache key, which is the case the
proposal opens with and a real one. It does nothing for N requests naming N
different sources — including the case the proposal calls the interesting one,
where every source is refused and no render is ever started, so the render queue
never sheds any of it. Against those, the numbers above are the whole story: 512
concurrent requests for distinct sources cost ~45 ms of contended CPU each and take
six seconds apiece to answer, on a box whose ffmpeg slots are meanwhile
untouched. Nothing in the proxy bounds that today except how many connections
Bandit accepted.

So the bound is a real backstop rather than a formality, and the requirement in
`specs/render-concurrency/spec.md` stands as written.

Two things the numbers also settle about *shape*:

- **A ceiling, not a scheduler.** Degradation is gradual — no cliff, no
  exhaustion — so the bound's job is to stop the tail, not to smooth the middle.
  It should sit well above `AP_MAX_CONCURRENCY` and be reached only by traffic
  that is pathological.
- **The default follows the cores, because the cost does.** `4 ×
  AP_MAX_CONCURRENCY` (whose own default is `System.schedulers_online()`) puts
  the default ceiling at 40 on this box: past the throughput knee, comfortably
  inside the region where a probe still answers in a quarter of a second, and
  four times the render cap so the "a probe never queues behind an encoder"
  property is visible in the arithmetic rather than only in the code.

## Known limits, accepted deliberately

Surfaced by the adversarial review round and recorded rather than fixed. Each is
either stated in `AudioProxy.ProbeCoordinator`'s moduledoc already or an exact
copy of a shape `AudioProxy.RenderCoordinator` ships today; changing any of them
here would make the two paths stop matching, which costs more than it buys.

- **A verdict that arrives after a waiter's deadline is never collected.**
  `ProbeCoordinator.await/2`'s drain is `after 0` and there is no barrier that
  could make it exact — nothing a waiter can do stops the coordinator. The
  message can then never match again (the coordinator pid is in the pattern), so
  on a keep-alive connection one accumulates per timed-out probe. It takes a
  probe outrunning `AP_PROBE_TIMEOUT` plus the margin to happen at all.
- **The start-or-join retry loop has no overall deadline.** Five attempts at a
  five-second join timeout is a 25-second worst case on a request path, reachable
  only by a coordinator that is wedged five times in a row.
  `AudioProxy.RenderCoordinator` has the identical constants.
- **An abnormal runner exit *after* a verdict has been broadcast is silent.** The
  verdict is already delivered and valid, so there is nothing to report to a
  client; what is lost is a log line about something odd having happened in a
  process that had already done its job.

## Risks / Trade-offs

- [A probe bound adds a queue in front of the cheapest part of the request] → keep the bound high relative to `AP_MAX_CONCURRENCY`; the point is a ceiling, not scheduling.
- [Coalescing probes couples two request paths that currently share nothing before the render] → the coordinator already monitors subscribers and cleans up on crash; reuse that discipline rather than a second lifecycle.
- [Sharing a probe result means sharing a *stale* one if a source changes mid-flight] → the window is one probe's lifetime, and the render that follows reads the same bytes the probe did. Not worse than the status quo, where each request probes and then renders separately.
- [Measurement may say the whole thing is unnecessary] → then this change closes with the numbers in the archive, which is a better outcome than the code.
