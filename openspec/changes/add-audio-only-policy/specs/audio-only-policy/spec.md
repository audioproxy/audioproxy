## ADDED Requirements

### Requirement: Sources containing video are rejected
The system SHALL reject processing of sources that contain one or more genuine video streams with a 415 error naming the video-input policy, on **every** signed endpoint — renders before any render subprocess starts, and `/info` before it describes anything. Attached-picture streams (`attached_pic` disposition — embedded cover art) SHALL NOT count as video.

#### Scenario: /info refuses video too
- **WHEN** `/info` is requested for a source containing both audio and video
- **THEN** the response is 415 with the same error the render endpoint gives, rather than a description of the audio stream

#### Scenario: Video file rejected
- **WHEN** a render is requested for an mp4 containing video and audio streams
- **THEN** the response is 415 with a JSON error naming the video-input policy, and no render subprocess was spawned

#### Scenario: Video-only file rejected
- **WHEN** a render is requested for a video-only source
- **THEN** the response is 415

#### Scenario: Cover art is not video
- **WHEN** a render is requested for an mp3 with embedded cover art (attached_pic mjpeg stream)
- **THEN** the render proceeds normally

#### Scenario: Gate precedes render
- **WHEN** a video source is requested
- **THEN** the probe gate rejects it without consuming a semaphore slot or starting ffmpeg

### Requirement: No ffmpeg option can be introduced through the URL
The system SHALL guarantee that every `-`-prefixed token in any render argv belongs to a fixed audio-only flag allowlist, and that no URL-derived value (option value, source URL, filename) can be interpreted as an ffmpeg flag.

#### Scenario: Argv allowlist holds for all options
- **WHEN** argv is built for randomly generated valid option sets (property test)
- **THEN** every flag token is a member of the published allowlist

#### Scenario: Flag smuggling via option values
- **WHEN** a request attempts to smuggle flags through option values or filenames (e.g., a `dl` name or `cb` value starting with `-filter_complex`)
- **THEN** the value is either rejected by validation (422) or appears in argv solely as a non-flag argument value

#### Scenario: No video encoder configurable
- **WHEN** argv is built for every supported output format
- **THEN** no video codec or video filter token appears

### Requirement: ffmpeg input protocols are restricted
The system SHALL invoke ffmpeg with a protocol whitelist containing only the protocols required for HTTPS input (`https,tls,tcp`; `http` only when a plaintext dev endpoint is configured), so that redirects or crafted inputs cannot reach `file:`, `concat:`, or other pivots.

#### Scenario: Whitelist always present
- **WHEN** any render argv is built
- **THEN** it contains the `-protocol_whitelist` flag with exactly the configured protocol set

#### Scenario: Pivot attempt fails at ffmpeg (integration)
- **WHEN** ffmpeg is handed an input that redirects to or references a `file:` URL under the whitelist
- **THEN** the render fails as a source error rather than reading the local file
