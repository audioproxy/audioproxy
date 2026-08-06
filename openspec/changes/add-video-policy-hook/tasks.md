## 1. Seam

- [ ] 1.1 `AudioProxy.VideoPolicy` behaviour (`verdict/1` over the probe result → `:reject | :extract`), default `Reject` module, app-env lookup at the gate call site
- [ ] 1.2 `:extract` path through the render action: proceed to render with existing argv hardening; `/info` describes the audio stream under `:extract`

## 2. Tests

- [ ] 2.1 Existing gate suite green and unchanged against the default (the invisibility proof)
- [ ] 2.2 Test-only policy: `:extract` renders a video fixture's audio (`@tag :ffmpeg`), argv carries `-vn -sn -dn`, no video encoder token; `/info` describes audio
- [ ] 2.3 No `AP_*` surface: config suite asserts no new variable

## 3. Docs

- [ ] 3.1 One paragraph in `docs/ffmpeg-arguments.md`: the verdict seam, why ingest-policy and egress-hardening are independent layers
