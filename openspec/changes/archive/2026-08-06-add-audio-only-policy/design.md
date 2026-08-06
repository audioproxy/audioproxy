## Context

Three enforcement layers, ordered by cost: URL grammar (already closed-world — unknown option keys 422), argv construction (pure, property-testable), and a runtime probe gate (the only layer that can see inside the source). Layers are redundant by design — each catches what the previous can't.

## Goals / Non-Goals

**Goals:**
- Audio-only as a tested invariant at every layer, not an emergent property of the format enum.
- Zero new API surface — this is pure policy tightening.

**Non-Goals:**
- Audio-extraction-from-video as a feature (explicitly excluded by this policy; would be a deliberate future decision reversing it).
- Codec-level build trimming (`--disable-everything` ffmpeg builds — that's the distro-vs-source open question in CLAUDE.md, decided in `add-docker-release`).
- Rate limiting / quota (separate concern, out of v1 scope).

## Decisions

- **Reject-not-strip for video inputs**: stripping (`-vn` alone) would make the proxy a free audio-extraction service for arbitrary video — cost profile and abuse surface we explicitly don't want. 415 with a clear error is honest API behavior. Cover art (`attached_pic` disposition per stream in ffprobe output) is exempted because virtually every tagged mp3/flac/m4a carries it.
- **Probe gate placement**: in the render action after the cache-HIT check and before semaphore/coalescing — a rejected source must not consume a render slot. Probe cost (~1 header-read subprocess, reusing the info slice's `Ffprobe` + its shorter timeout) is paid only on MISS; HITs never probe. The probe result rides on the source's ETag identity, so a CDN-cached `/info`-style conditional flow keeps repeat MISS probes cheap.
- **`-vn -sn -dn` unconditionally** in the command builder baseline flags — belt and braces behind the gate; also protects the peaks PCM path and any future render mode by default.
- **Protocol whitelist per source type**, derived from the resolved source, never from user input: local → `file` only (no network reachable); HTTPS → `https,tls,tcp` (no filesystem reachable), plus `http` automatically when a plaintext dev endpoint (`AP_S3_ENDPOINT`-style) is configured. The two sets are disjoint by construction — a local invocation cannot fetch, a remote invocation cannot read disk. No env knob for protocols — a knob would reopen the hole this closes.
- **Allowlist test via `Command.allowed_flags/0`**: the builder publishes its own flag vocabulary; the property test asserts argv ⊆ vocabulary and the vocabulary contains no video/subtitle flags (deny-pattern check: no `-c:v`, `-filter:v`, `-vf`, `-map` beyond audio selectors). Two-sided: reality ⊆ allowlist, allowlist ∩ denylist = ∅.

## Risks / Trade-offs

- [Extra ffprobe per MISS adds latency] → header-read only (hundreds of ms worst case on cold S3, negligible on local files), amortized to zero by the variant cache; acceptable for the security/abuse win.
- [attached_pic detection quirks across containers] → fixture-driven tests per container (mp3/flac/m4a cover art); when disposition data is ambiguous, fail open only for streams whose codec is an image codec (mjpeg/png) with 1 frame — otherwise reject.
- [Protocol whitelist may need `crypto` scheme additions with ffmpeg upgrades] → whitelist asserted in integration tests against the pinned ffmpeg; an upgrade that changes protocol needs surfaces as a red test, not a silent behavior change.
- [**Probe fan-out is unbounded, and nothing coalesces probes** — deferred, needs its own change] → the gate runs before the semaphore (by design: a refused source must not hold a render slot) and before the coalescing registry, so N concurrent requests for one cache key spawn N ffprobes and exactly one render. `AP_PROBE_TIMEOUT` bounds each probe, nothing bounds the aggregate. This is a widening of a risk the project already accepted in writing for `/info` ("a header read is neither long nor CPU-bound"), and every request here is signature-gated, which is why it is not a blocker for this slice — but it is the one finding both the self-review and the adversarial CLI reached independently, so it is not being quietly dropped. Bounding it means either a probe-specific semaphore or extending the coalescing registry to cover the pre-render probe; both want measurements first, which is why it is a change and not a late edit here. **Board entry still to be created on `main`** (working name `bound-probe-concurrency`); this note is not the plan.

## Known limits, accepted deliberately

Both surfaced in the adversarial review and are recorded rather than fixed:

- **`attached_pic` is attacker-controllable.** The cover-art exemption trusts a container flag, so a crafted file can wear it. Bounded by the layer underneath: `-vn -sn -dn` means the video stream is never mapped, so a forged exemption buys audio extraction from a video file, not a video transcode. Written up in `docs/ffmpeg-arguments.md`.
- **The no-disposition fallback has no real-binary fixture.** ffmpeg's mp3 and flac muxers always write `attached_pic`, so a real source that omits it cannot be produced with the tools at hand — which is why the fallback is codec-name guesswork in the first place. It exists for containers we cannot enumerate, and the ones we can produce cannot exercise it. Pinned by the fake prober only, with the reason stated at the test.
- **A variant store populated before this change keeps serving.** The gate runs before a render, not before a cache hit, so audio extracted from video under the old behaviour serves for the full year its `Cache-Control` claims. Closing that is a purge, not code; stated in the README's upgrade note.
