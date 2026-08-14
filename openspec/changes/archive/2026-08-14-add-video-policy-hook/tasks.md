## 1. Seam

- [x] 1.1 `AudioProxy.VideoPolicy` behaviour (`verdict/1` over the probe result → `:reject | :extract`), default `Reject` module, app-env lookup at the gate call site

  `lib/audio_proxy/video_policy.ex` carries the behaviour, the closed enum, and
  two public functions: `verdict/1` (the app-env lookup and dispatch) and
  `admit/1` (the gate — `has_video?/1` paired with the verdict, returning
  `:ok | {:error, :video_source}`). Both call sites go through `admit/1` rather
  than pairing the two themselves, which is what makes "a policy is consulted
  about video and nothing else" an invariant one module holds instead of a
  convention two plugs share. A verdict outside the enum logs and refuses; the
  failure belongs to the embedding release, so a 500 would misattribute it.

- [x] 1.2 `:extract` path through the render action: proceed to render with existing argv hardening; `/info` describes the audio stream under `:extract`

  `admit/1` returns `:ok`, so the render proceeds through the same
  `Command.build/3` and the same admission control — the probe still runs before
  a semaphore slot is asked for, so `:extract` is not a way around the queue.
  `/info` falls through to `Ffprobe.contract/2`, which describes the first audio
  stream; §4 has no vocabulary for any other kind and gained none here.

## 2. Tests

- [x] 2.1 Existing gate suite green and unchanged against the default (the invisibility proof)

  `git diff --stat` touches no gate test file: `render_endpoint_ffmpeg_test.exs`,
  `info_endpoint_ffmpeg_test.exs` and `ffprobe_test.exs` are byte-identical, and
  1086 tests pass (up from 1074 by the 12 added here). The two `--only ffmpeg`
  failures are pre-existing and environmental — the host ffmpeg has no
  `libvorbis`, confirmed failing identically on `main`.

  Mutated rather than read, per the project rule. Flipping the default in
  `Reject` to `:extract` fails **12 tests and 1 doctest** in the fast suite
  alone; inverting `admit/1` so the policy is consulted before `has_video?/1`
  fails the audio-only invariant test. Both restored.

- [x] 2.2 Test-only policy: `:extract` renders a video fixture's audio (`@tag :ffmpeg`), argv carries `-vn -sn -dn`, no video encoder token; `/info` describes audio

  `test/audio_proxy/video_policy_test.exs` covers the seam against hand-built
  probe maps, including the three boundaries: cover art is still not video under
  an extracting policy, an audio-only source never reaches the policy (asserted
  with a policy that raises), and an invented verdict refuses.

  The egress half is asserted structurally rather than by inspection: the argv
  is compared byte-for-byte under both verdicts, every format's argv is checked
  for `-vn -sn -dn` as a contiguous run, and no format's argv carries `-c:v` or
  any video codec token.

  `test/audio_proxy/video_policy_ffmpeg_test.exs` runs it end to end — the mp4
  fixture renders as a decodable 2 s mp3, the returned bytes have no video
  stream (the guarantee *measured on the output*, not read off the builder),
  `/info` reports rate, channels and duration, and a tripwire asserts the
  fixture really is video with no `attached_pic`.

- [x] 2.3 No `AP_*` surface: config suite asserts no new variable

  A new describe block in `config_test.exs`: no published variable matches
  `VIDEO|POLICY|EXTRACT`, and four plausible spellings (`AP_VIDEO_POLICY`,
  `AP_VIDEO`, `AP_EXTRACT_VIDEO`, `AP_ALLOW_VIDEO`) each build a config equal to
  the empty-environment baseline — the variable is not merely unpublished, it is
  read into nothing. A `Map.has_key?` check would have been a tautology, since
  the struct's keys are fixed at compile time. The verdict is asserted to still
  be `:reject` afterwards, since a lever could also live outside `Config`.

  `llms-full.txt` is deliberately untouched: no option, error code, endpoint or
  configuration variable changed, so there is no API-surface delta to publish.

## 3. Docs

- [x] 3.1 One paragraph in `docs/ffmpeg-arguments.md`: the verdict seam, why ingest-policy and egress-hardening are independent layers

  Added to *Audio only, at the argv*, directly after the existing two-layer
  argument it extends. The independence is stated as a property of the
  signature: `Command.build/3` takes the options, the input and the source type,
  and no policy is among its arguments — so `-vn -sn -dn` cannot be conditional
  on a verdict it never sees. Also says why the knob is application env rather
  than an `AP_` variable, so the configuration surface's silence is explained
  where a reader would otherwise notice the gap.
