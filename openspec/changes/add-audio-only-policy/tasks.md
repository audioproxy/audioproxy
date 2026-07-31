## 1. Command builder hardening

- [ ] 1.1 Baseline flags gain `-vn -sn -dn` and `-protocol_whitelist` (set from config: `https,tls,tcp` + conditional `http` for plaintext dev endpoints); applies to audio and PCM/peaks modes
- [ ] 1.2 `Command.allowed_flags/0` introspection
- [ ] 1.3 Tests: flags present for every format + peaks mode; property test argv ⊆ allowed_flags; denylist check (no `-c:v`/`-vf`/`-filter:v`/video mapping tokens in the vocabulary); flag-smuggling attempts via `dl`/`cb` values stay non-flag argv values

## 2. Probe gate

- [ ] 2.1 Video detection on `Ffprobe` output: genuine video streams vs `attached_pic`/single-frame image codecs; `has_video?/1` with unit tests over canned probe JSON (mp4 a+v, video-only, mp3+cover, flac+cover, ambiguous disposition)
- [ ] 2.2 Render action: probe after HIT-check, before semaphore/coalescing; video → 415 (`ErrorJSON` gains the video-input reason); no slot consumed (assert via semaphore probe in tests)
- [ ] 2.3 Integration (`@tag :ffmpeg`): lavfi-generated mp4 (testsrc+sine) → 415; mp3 with embedded cover art → renders; protocol pivot attempt (redirect to `file:`) fails as source error

## 3. Docs

- [ ] 3.1 Amend `docs/audio-proxy-api-v1.md`: §3.1 audio-only policy note, §5 415 wording ("not decodable or contains video")
- [ ] 3.2 Update README (policy statement, 415 semantics) and llms content if `add-llms-txt` has landed (error-table drift guard will enforce)
