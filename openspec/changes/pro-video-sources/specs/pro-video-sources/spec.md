## ADDED Requirements

### Requirement: Licensed extraction from video sources
With a valid license carrying the `video_sources` feature, sources containing video SHALL render audio variants, answer `/info` with the audio stream's description, and produce peaks and measurements — using ffmpeg's default audio-stream selection, with every processing option and cache-key rule unchanged.

#### Scenario: Video podcast to feed audio
- **WHEN** a licensed deployment renders `f:mp3/br:128` of an mp4 master
- **THEN** the response is the episode's audio as mp3, byte-cacheable under the same key rules as any variant

#### Scenario: Peaks from a video source
- **WHEN** `f:peaks` is requested for a licensed video source
- **THEN** waveform data for the audio track returns, suitable for a scrubber under a video player

### Requirement: Egress remains audio-only
Extraction SHALL never map or encode a video stream: `-vn -sn -dn` and the audio-only encoder vocabulary hold on every licensed render, verified by the same argv property suite OSS runs.

#### Scenario: Argv under license
- **WHEN** a licensed render of a video source is built
- **THEN** argv contains the stream-disable flags and no video codec or filter token

### Requirement: Unlicensed behavior is exactly OSS
Without the feature flag — absent, expired, or invalid license — video-containing sources SHALL be rejected precisely as OSS specifies (415, same body), consistent with the degrade-to-OSS contract.

#### Scenario: Expiry mid-operation
- **WHEN** the license expires and the node reboots
- **THEN** video sources answer the OSS 415 while audio sources serve normally, and the degradation is logged loudly
