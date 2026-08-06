## 1. License gate

- [ ] 1.1 `video_sources` claim → extraction policy configured at wrapper boot; absent/expired/invalid → OSS default, loud log
- [ ] 1.2 Tests: flag present → extract; each degradation path → OSS 415 byte-identical; expiry-then-reboot scenario

## 2. Behavior surface

- [ ] 2.1 `@tag :ffmpeg` fixtures (lavfi testsrc+sine mp4/mov, real attached_pic audio for the non-regression): render, `/info`, peaks, measurement against licensed video sources
- [ ] 2.2 Argv property suite runs over video-source renders (stream-disable flags, encoder vocabulary)
- [ ] 2.3 Upload-policy composition test: policy line producing audio set from a video ingest ping

## 3. Docs

- [ ] 3.1 PRO docs: capability page (extraction framing, default-track semantics, `tr:` named as follow-up, lapsed-license cache caveat); pricing page gains the feature flag
