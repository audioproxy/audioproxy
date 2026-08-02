## Context

First `pro-` slice: PRO-scoped, structured for later extraction into a separate repo (prefixed change and capability, no amendments to any other change or spec). Everything it runs on is OSS machinery: the command builder gains an analysis mode, the port wrapper runs it, coalescing/semaphore govern it.

## Goals / Non-Goals

**Goals:**
- Accurate per-source loudness numbers, cheap on repeat (HTTP-cacheable, coalesced), safe under load (slot-governed).

**Non-Goals:**
- Applying measurements at render time (true two-pass `norm` — a future change extending the processing-options grammar).
- Group/album arithmetic (a later PRO slice consuming this endpoint).
- Persisting measurements server-side — the HTTP cache layer (ETag/304 + CDN) is the store; no database, per the core posture.

## Decisions

- **`measure` as an exclusive pseudo-option** in the options position, exactly like `info` — same grammar rule, same 422 on stray options, same routing shape. No new URL surface to sign differently.
- **Analysis argv**: `-af loudnorm=print_format=json -f null -` — a decode-only pass writing the measurement to stderr; the builder treats it as a mode like peaks PCM (additive vocabulary, `-vn -sn -dn` and protocol rules inherited when those land). Stderr here is the *payload*, not diagnostics — the port wrapper's collect mode captures it and the action parses the trailing JSON block.
- **Coalesce on a measurement-specific cache key** (`measure ‖ canonical source`) through the same registry as renders — one in-flight pass per source, late requesters get the same parsed result.
- **Tolerance-based tests** (±0.5 LU / ±0.5 dB against lavfi-generated known signals) — loudnorm's measured values vary slightly across ffmpeg builds; the pinned-image integration suite is what holds the exact behavior still.
- **Numbers, not advice**: the endpoint returns measurements only. How to apply them (a `gain:` value, future measured-`norm` params, group offsets) is the caller's or a later slice's business — keeps this endpoint stable while the consumers evolve.

## Risks / Trade-offs

- [A measurement is a full decode of a possibly hour-long master] → slot-governed and coalesced; `AP_RENDER_TIMEOUT` bounds it like any render. Operators measuring large catalogs do it through the (future) warm/policy machinery, paced by the queue.
- [loudnorm JSON on stderr mixes with real diagnostics on failure] → parse only a trailing well-formed JSON block on exit 0; nonzero exits go through the ordinary failure classification.
- [Extraction to a separate repo later] → the change is self-contained by construction; the move is `git mv` of the change/spec plus relocating the measure action module — no delta surgery.
