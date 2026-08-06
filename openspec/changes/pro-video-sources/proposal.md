## Why

Video-first audio is now the norm in podcasting, and STT/AI pipelines transcribe video libraries — both currently pre-extract audio in their own tooling because this proxy refuses video containers. The refusal's real target was video *processing*; extraction was never that: pulling the audio track decodes no video frame, keeps CPU audio-shaped, and never loads video encoders. This rung licenses video **ingest** while OSS's audio-only **egress** guarantee stands untouched — the sixth PRO rung, riding the neutral seam `add-video-policy-hook` provides.

## What Changes

- A `video_sources` feature flag in the license claims; when present and valid, the PRO wrapper configures the extraction policy — unlicensed or expired degrades to the OSS rejection, per the license-degradation contract.
- Video-containing sources then render audio variants, feed `/info` (audio-stream description), `f:peaks`, and the PRO measurement endpoint. Every existing option applies unchanged; cache keys, signing, coalescing, stores are untouched.
- v1 track semantics: ffmpeg's default audio-stream selection (first/best audio stream). **Multi-track selection (`tr:`/`lang:`) is deliberately a follow-up** — it is the first new cache-key-relevant URL option in a long time and deserves its own round-trip treatment; this rung ships without it and says so.
- Upload policies (rung 3) compose: "new `episode.mp4` → mp3 + opus preview + peaks" becomes one policy line.

## Capabilities

### New Capabilities

- `pro-video-sources`: the license gate over the extraction policy, the per-endpoint behavior on video sources, and the degradation contract.

### Modified Capabilities

<!-- none — consumes the audio-only-policy seam; zero OSS deltas -->

## Impact

- New (PRO repo eventually): license-flag check wiring the extraction policy at boot.
- Depends on: `add-video-policy-hook` (the seam), the PRO license verifier (rung-infrastructure), and probe-gate machinery (merged).
- Explicitly out: video thumbnails / frames-out (different risk and CPU profile — a separate product decision, recorded in the PRO notes, not a rung).
- Position: rung 6, unscheduled; trigger = first video-podcast or STT-pipeline prospect.
