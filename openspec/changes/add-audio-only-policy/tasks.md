## 1. Command builder hardening

- [x] 1.1 Baseline flags gain `-vn -sn -dn` and `-protocol_whitelist`; applies to audio and PCM/peaks modes. Built **per source type**, not from config — `local` → `file`, `https` → `https,tls,tcp`, `s3` → the same plus `http` only when `AP_S3_ENDPOINT` is cleartext. That is what `design.md` and both delta specs require; this line's original "set from config" wording predated the decision. `build/3` therefore requires `type:` — a default would be a guess about which side of the network/filesystem boundary a render sits on
- [x] 1.2 `Command.allowed_flags/0` introspection
- [x] 1.3 Tests: flags present for every format + peaks mode; property test argv ⊆ allowed_flags; denylist check (no `-c:v`/`-vf`/`-filter:v`/video mapping tokens in the vocabulary); flag-smuggling attempts via `dl`/`cb` values stay non-flag argv values

## 2. Probe gate

- [x] 2.1 Video detection on `Ffprobe` output: genuine video streams vs `attached_pic`/single-frame image codecs; `has_video?/1` with unit tests over canned probe JSON (mp4 a+v, video-only, mp3+cover, flac+cover, ambiguous disposition)
- [x] 2.2 Render action: probe after HIT-check, before semaphore/coalescing; video → 415 (`ErrorJSON` gains the video-input reason); no slot consumed (assert via semaphore probe in tests)
- [x] 2.2b `/info` gated on the same rule, resolving "render and info-adjacent" in the requirement: the endpoint reads the probe it had already paid for, so the policy has no endpoint-shaped exception and `/info` is not metadata extraction for arbitrary video. `-select_streams a:0` dropped from the probe flags — a gate cannot refuse a stream ffprobe was told to hide, and §4's object is unaffected because `contract/2` finds the first audio stream itself
- [x] 2.3 Integration (`@tag :ffmpeg`): lavfi-generated mp4 (testsrc+sine) → 415; mp3 with embedded cover art (real `attached_pic`) → renders, with a tripwire asserting the fixture really carries the disposition. The pivot half is exercised at the argv level in `command_ffmpeg_test.exs` rather than through a redirect: no remote source backend exists yet to redirect *from*, so the reachable assertion is that real ffmpeg refuses `file:` under the remote whitelist, refuses `https:` under the local one, and refuses `concat:` under both

## 3. Docs

- [x] 3.1 Amend `docs/audio-proxy-api-v1.md`: §3.1 audio-only policy note, §5 415 wording ("not decodable or contains video")
- [x] 3.2 Update README (policy statement under *Sources*, the `video_source` error row, the HEAD caveat, the roadmap's "deliberately not planned" line) plus `docs/ffmpeg-arguments.md` for the argv-level half. No llms content to update — `add-llms-txt` has not landed
