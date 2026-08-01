## 1. Render action

- [ ] 1.1 `Source.ffmpeg_input/1` handoff replacing the 501 placeholder (single spawn call site for the later coordinator swap). Never bypass the seam to reach the filesystem: `ffmpeg_input/1` is what refuses non-regular files, and a FIFO handed to ffmpeg blocks forever on a read that never completes
- [ ] 1.1a Decide the TOCTOU posture for local sources and record it in `design.md`: pin the inode (open the file, hand ffmpeg `/dev/fd/N`, which also settles the `-protocol_whitelist` story) or accept the exposure explicitly with the read-only-root deployment assumption the README states. Raised by the adversarial review of `add-local-files-source`; do not inherit it silently
- [ ] 1.2 Spawn `Ffmpeg.Render` with the endpoint process as consumer; send §5 headers (Content-Type, Cache-Control, ETag, `X-Audio-Proxy: MISS`, optional Content-Disposition); chunked streaming receive-loop
- [ ] 1.3 Disconnect handling: `chunk/2` error → cancel render/exit; receive-deadline → 504 pre-stream, abnormal close mid-stream; remove the 501 pinning test

## 2. Tests

- [ ] 2.1 Full-stack (`@tag :ffmpeg`): fixture WAV from a local fixture dir (`AP_LOCAL_ROOT`) → decodable mp3/opus; first-chunk-before-completion timing; §5 header assertions on the 200
- [ ] 2.2 Disconnect (`:gen_tcp`): sole client closes mid-stream → ffmpeg pid dead (probe process table)
- [ ] 2.3 Render failures end-to-end: text-file source → 415, `fake_cmd` hang → 504 pre-stream, mid-stream kill → abnormal close

## 3. Docs

- [ ] 3.1 Update README: endpoint usage walkthrough (sign → curl → stream, local source)
