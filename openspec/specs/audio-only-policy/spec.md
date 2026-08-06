# audio-only-policy Specification

## Purpose
This is an audio proxy, and that is enforced rather than assumed. Before this
capability existed it was an emergent property of the format enum: every output
format happened to be audio, so nothing refused a video *input* — a
video-container source simply had its audio track extracted, on request, for
anyone holding a signed URL.

That is a different product, and three costs make it one worth refusing. Video
decode is orders of magnitude more expensive than audio, so it turns the public
URL surface into a CPU-abuse vector. Video codecs carry the bulk of ffmpeg's CVE
history, so it widens the attack surface of the one dependency that actually
parses untrusted bytes. And ffmpeg's exotic input protocols — `concat:`,
`file:`, `subfile:` — are SSRF and file-read pivots that have nothing to do with
audio at all.

**Reject, do not strip.** `-vn` alone would have been cheaper and is the wrong
answer: it would make the proxy a free audio-extraction service for arbitrary
video, at video's cost profile, while reporting success. A 415 naming the policy
is honest about what the proxy will and will not do. The cost of that choice is
that cover art has to be exempted explicitly, because virtually every tagged
mp3, flac and m4a in a real catalogue carries an embedded picture as a
video-typed stream, and refusing those would refuse most of a working library.

The policy holds at three layers, ordered by cost, and they are redundant on
purpose — each catches what the one before it cannot see:

1. **The URL grammar** is already closed-world: an unknown option key is a 422,
   so no ffmpeg option can be named by a client. What this capability adds is
   that the guarantee is *checked* rather than assumed, by publishing the flag
   vocabulary and asserting every built argv against it.
2. **The argv** disables non-audio streams and restricts input protocols, for
   every format and every render (see `ffmpeg-args`). Pure, property-testable,
   and independent of anything the probe below discovers.
3. **A runtime probe** is the only layer that can see *inside* a source, and so
   the only one that can refuse video at all.

Where that probe runs is as load-bearing as what it decides. It sits after the
variant-cache lookup, so a cache hit never pays for it, and before the
concurrency semaphore, so a source about to be refused never occupies a render
slot. Both endpoints gate: `/info` reads the probe it was already running, which
keeps the policy free of an endpoint-shaped exception and stops `/info` being a
metadata-extraction service for arbitrary video.

Two consequences follow from the placement and are deliberate rather than gaps.
A `HEAD` spawns no subprocess, so it answers `200` where a `GET` on a miss
answers `415`; and a cache hit serves immutable bytes that passed the gate when
they were rendered — which means a variant store populated *before* this
capability existed keeps serving what it holds until it is purged.

Detection fails closed. An unrecognized codec, an absent frame count, or a
disposition map that says nothing is treated as video. The cost of that
direction is a 415 on an odd file; the cost of the other is the video transcoder
this capability exists to not be. The one exemption that trusts container
metadata (`attached_pic`) is trusting bytes the requester may control, so a
crafted file can wear it — which is exactly why layer 2 is unconditional: with
the video stream never mapped, forging the exemption buys audio extraction
rather than a video transcode.

## Requirements

### Requirement: Sources containing video are rejected
The system SHALL reject processing of sources that contain one or more genuine video streams with a 415 error naming the video-input policy, on **every** signed endpoint — renders before any render subprocess starts, and `/info` before it describes anything. Attached-picture streams (`attached_pic` disposition — embedded cover art) SHALL NOT count as video.

#### Scenario: Video file rejected
- **WHEN** a render is requested for an mp4 containing video and audio streams
- **THEN** the response is 415 with a JSON error naming the video-input policy, and no render subprocess was spawned

#### Scenario: Video-only file rejected
- **WHEN** a render is requested for a video-only source
- **THEN** the response is 415

#### Scenario: Cover art is not video
- **WHEN** a render is requested for an mp3 with embedded cover art (attached_pic mjpeg stream)
- **THEN** the render proceeds normally

#### Scenario: Ambiguous disposition data fails closed
- **WHEN** a video-typed stream carries no `attached_pic` disposition and is not a single frame of an image codec
- **THEN** it counts as video and the source is refused

#### Scenario: Gate precedes render
- **WHEN** a video source is requested
- **THEN** the probe gate rejects it without consuming a semaphore slot or starting ffmpeg

#### Scenario: /info refuses video too
- **WHEN** `/info` is requested for a source containing both audio and video
- **THEN** the response is 415 with the same error the render endpoint gives, rather than a description of the audio stream

#### Scenario: The refusal is distinguishable from a decoding failure
- **WHEN** a source is refused for containing video
- **THEN** the error names the policy rather than reporting the source as undecodable, since the source decodes perfectly well

#### Scenario: A cache hit does not probe
- **WHEN** a variant is already in the variant store
- **THEN** it is served without a probe, because a stored variant is immutable bytes that passed the gate when they were rendered

### Requirement: No ffmpeg option can be introduced through the URL
The system SHALL guarantee that every `-`-prefixed token in a flag position of any render argv belongs to a fixed audio-only flag allowlist, and that no URL-derived value (option value, source URL, filename) can be interpreted as an ffmpeg flag.

#### Scenario: Argv allowlist holds for all options
- **WHEN** argv is built for randomly generated valid option sets (property test)
- **THEN** every flag token is a member of the published allowlist

#### Scenario: Flag smuggling via option values
- **WHEN** a request attempts to smuggle flags through option values or filenames (e.g., a `dl` name or `cb` value spelled `-filter_complex`)
- **THEN** the value is either rejected by validation (422) or absent from argv entirely, leaving it byte-identical to the same request without it

#### Scenario: Flag smuggling via the source
- **WHEN** the resolved input is itself flag-shaped (`-vf`, `--`)
- **THEN** it appears in argv solely as the value of `-i`, and changes no other element

#### Scenario: No video encoder configurable
- **WHEN** argv is built for every supported output format
- **THEN** no video codec or video filter token appears

### Requirement: ffmpeg input protocols are restricted
The system SHALL invoke every ffmpeg-family subprocess that reads a source — the render and both probe routes — with a protocol whitelist containing only the protocols that source type requires, so that redirects or crafted inputs cannot reach `file:`, `concat:`, or other pivots.

The whitelist SHALL be derived from the resolved source's type and SHALL NOT be defaultable: a caller with no protocol set to offer cannot start a subprocess that reads a source.

#### Scenario: Whitelist always present
- **WHEN** any render argv is built
- **THEN** it contains the `-protocol_whitelist` flag with exactly the source type's protocol set

#### Scenario: Probes are restricted too
- **WHEN** a source is probed — by `/info`, by the audio-only gate, or by the peaks pipeline, which builds its own probe argv
- **THEN** the probe carries the same whitelist the render would, and a probe requested without one raises rather than running unrestricted

#### Scenario: The two sets are disjoint
- **WHEN** the local and remote protocol sets are compared
- **THEN** they share no protocol, so a local invocation cannot fetch and a remote invocation cannot read disk

#### Scenario: Pivot attempt fails at ffmpeg (integration)
- **WHEN** ffmpeg is handed an input that redirects to or references a `file:` URL under the remote whitelist, or a network URL under the local one
- **THEN** the render fails as a source error rather than reading the local file or issuing the fetch
