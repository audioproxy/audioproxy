## Context

Pure consumer of the `add-video-policy-hook` seam, gated by the license claims. The interesting design was done upstream (probe, attached_pic, argv hardening); this rung is a feature flag plus honesty about tracks.

## Goals / Non-Goals

**Goals:** video ingest for audio egress, licensed; identical behavior surface to audio sources otherwise.

**Non-Goals:** track selection (follow-up option with full round-trip treatment); frames-out/thumbnails (not a rung — separate product decision); any change to what unlicensed deployments do.

## Decisions

- **Boot-time policy wiring**: the wrapper reads the verified claims once and sets the policy module — no per-request license checks; expiry takes effect on restart, consistent with the license model's boot-verification posture.
- **Default track = ffmpeg's selection** for v1: predictable, documented, and honest — multi-track catalogs (languages, commentary) get the `tr:` option as its own change because it enters the cache key.
- **Probe cost unchanged**: the gate already probes every source; a licensed video source pays exactly what an audio source pays.
- **Cache immutability caveat carried over**: variants cached under a license remain served if the license lapses (the store doesn't know); documented, mirrors the OSS pre-gate-variant note.

## Risks / Trade-offs

- [Container/demuxer surface widens past probe into demux] → same pinned-ffmpeg posture as everything else; the probe already parses these containers in OSS, and video *decoders* still never run.
- [Track defaults surprise multi-language catalogs] → documented limitation with the `tr:` follow-up named; wrong-track output is deterministic and cache-consistent, never corrupt.
