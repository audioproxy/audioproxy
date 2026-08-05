## Why

`add-audio-only-policy` put an `ffprobe` on the render path: every MISS probes the source before it renders, so a video input is refused before a render slot is taken. That placement is right, and it introduced the one gap both that change's self-review and its adversarial review reached independently.

Probes are bounded per-probe and unbounded in aggregate. A probe deliberately takes no `AP_MAX_CONCURRENCY` slot — the semaphore rations *encoders*, and queueing a header read behind a transcode would make `/info` the slowest thing in the proxy — and the gate runs *before* the coalescing registry, because a source that will be refused must not join a render. Both decisions are sound in isolation, and together they mean:

- N concurrent requests for one cache key spawn N probes and exactly one render. The registry that exists to stop duplicate work does not cover the work that now happens ahead of it.
- A `f:peaks` MISS pays **two** probes, not one: the gate's, and the one `AudioProxy.Peaks.Render` runs to learn the frame count its bucket boundaries need. They ask ffprobe the same question about the same bytes, moments apart, and neither knows about the other — so on that format the sharing this change is about is worth double.
- N concurrent requests for a *refused* source spawn N probes and no render at all, so the render queue — the thing that sheds load with a 429 — never sees them.
- `AP_PROBE_TIMEOUT` bounds each probe's lifetime; nothing bounds how many exist. The ceiling is the number of open connections, which is a Bandit setting nobody picked as a subprocess limit.

Every request here is signature-gated, and against a local file a probe is short and cheap, which is why this was not a blocker for the slice that introduced it. It is still the wrong shape: the proxy has one carefully-rationed subprocess pool and one unrationed one, and the unrationed one is reachable on the endpoint that matters.

`/info` has had this property since it shipped and the project accepted it in writing. What changed is the blast radius: it is now every render, not one endpoint a client calls occasionally.

## What Changes

- **Measure before choosing.** What a probe actually costs — spawn, header read, teardown — against a local file and against an HTTP source, and how many concurrent probes a box tolerates before scheduler time or file descriptors become the binding constraint. The numbers decide which of the next two items is worth building; shipping both without them would be guessing twice.
- **Coalesce probes per cache key**, so concurrent requests for one variant share one probe result the way they already share one render. Likely the bigger win and the smaller change: the registry and the broadcast already exist.
- **Bound concurrent probes**, if the measurements say a bound is still needed once probes coalesce. A probe-specific counter rather than the render semaphore: they ration different resources, and a shared cap would reintroduce exactly the queueing the probe path was designed to avoid. An exhausted probe bound answers 429 with `Retry-After`, reusing the semaphore's vocabulary rather than inventing a status.
- **Where the result is remembered, if anywhere.** A probe verdict rides on the source's identity, not the variant's, so a cache would be keyed differently from everything else in the proxy — which is a reason to be careful, not a reason to skip the question.

## Capabilities

### Modified Capabilities

- `render-concurrency`: probes are rationed, and the document says what a slot counts and what it does not.
- `render-coalescing`: the pre-render probe joins the work a cache key shares.
- `source-info`: `/info` inherits whatever bound lands.

## Impact

- Modified: `lib/audio_proxy/ffprobe.ex`, `lib/audio_proxy/render_coordinator.ex` (or a probe-specific sibling), `lib/audio_proxy/plugs/render_action.ex`, `lib/audio_proxy/plugs/info_action.ex`, `lib/audio_proxy/semaphore.ex` if a second counter is the answer.
- Depends on: `add-audio-only-policy` (the change that put a probe on the render path).
- Deferred from that change with the reasoning recorded in its `design.md`, which names this change.
