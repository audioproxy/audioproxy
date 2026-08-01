## Why

The proxy must never become an accidental video transcoder or a generic ffmpeg gateway. Video decode/encode is orders of magnitude more expensive than audio (CPU-abuse vector through the public URL surface), video codecs carry the bulk of ffmpeg's CVE history, and ffmpeg's exotic input protocols (`concat:`, `file:`, `subfile:`) are SSRF/file-read pivots. Today this is implicit — the format enum happens to be audio-only; this slice makes audio-only an enforced, tested policy at every layer.

## What Changes

- **Video inputs are rejected**: a pre-render ffprobe gate returns 415 for sources containing genuine video streams. Attached-picture streams (cover art in mp3/flac/m4a) are exempt — they are metadata, not video.
- **Video/subtitle/data streams never map**: every render argv carries `-vn -sn -dn` unconditionally (defense in depth behind the probe gate), and no video encoder can ever appear in argv.
- **No ffmpeg option passthrough**: the API's closed-world grammar (unknown keys → 422) is elevated to a tested guarantee — every `-`-prefixed argv token must come from a fixed allowlist of audio-only flags; no URL content can introduce a flag.
- **Input protocols restricted per source type**: ffmpeg runs with `-protocol_whitelist` derived from the resolved source — `file` only for local sources (no network reachable), `https,tls,tcp` for HTTPS sources (no filesystem reachable; `http` added only when a plaintext dev endpoint is configured) — so even a compromised or redirecting source cannot pivot ffmpeg across boundaries.
- API doc amended (§3.1 note + §5 error table) to state the policy: 415 covers "not decodable *or contains video*".

## Capabilities

### New Capabilities

- `audio-only-policy`: Input video rejection, argv flag allowlisting, and ffmpeg protocol restriction.

### Modified Capabilities

- `ffmpeg-args`: Every render argv SHALL disable video/subtitle/data streams and restrict input protocols per source type (delta on the command-builder spec).

## Impact

- Modified: `lib/audio_proxy/ffmpeg/command.ex` (stream-disable flags, per-source-type protocol whitelist, allowlist introspection for tests), render action (probe gate before subscribing), `docs/audio-proxy-api-v1.md`.
- Depends on: `add-ffmpeg-command-builder`, `add-render-endpoint`, `add-info-endpoint` (reuses its `Ffprobe` module for the gate), `add-local-files-source` (the local source type the whitelist dispatches on). The HTTPS half of the whitelist becomes reachable with `add-remote-files-source`; until then only the `file` set is exercised.
- Position: post-MVP, directly after `add-info-endpoint`. Until it lands, video-container sources get their audio track extracted rather than rejected — the `-vn` defense can be cherry-picked into the command builder earlier if that window matters.
