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
