## Why

The audio-only gate's verdict ("contains genuine video → 415") is hard-wired at its call site. A licensed PRO capability (video-in/audio-out extraction) needs to change the *verdict*, not the machinery — the probe, the `attached_pic` nuance, and `-vn -sn -dn` are exactly right for extraction too. This is the `add-semaphore-classes` pattern again: a neutral OSS seam, provably invisible until a consumer speaks, so the PRO wrapper stays a pure consumer with zero OSS deltas.

## What Changes

- The gate's verdict moves behind a policy module (`:audio_proxy, :video_policy`, default `AudioProxy.VideoPolicy.Reject`): input is the probe result, output is `:reject | :extract`. The default reproduces today's behavior byte-for-byte.
- `:extract` is *defined* but unreachable in OSS: no OSS configuration selects any module but the default — the knob is application-env only, set by an embedding release (the intended consumer), never by an `AP_*` var.
- Egress stays audio regardless of verdict: `-vn -sn -dn` and the no-video-encoder vocabulary are untouched — the policy governs *ingest* only, by construction.

## Capabilities

### New Capabilities

<!-- none -->

### Modified Capabilities

- `audio-only-policy`: the rejection verdict is derived from a policy module whose default SHALL reject; the rejection behavior itself is unchanged.

## Impact

- Modified: the gate call site, one policy behaviour + default module.
- Depends on: merged code only. Consumers: `pro-video-sources` (first), none in OSS.
- Position: unscheduled — implemented when rung 6 schedules; harmless earlier (default-indistinguishable, tested as such).
