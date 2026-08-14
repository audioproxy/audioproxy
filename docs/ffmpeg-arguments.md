# How options become ffmpeg arguments

Implementation reference for `AudioProxy.Ffmpeg.Command`. Nothing here is
needed to *use* the proxy — the
[option grammar](audio-proxy-api-v1.md#3-processing-options) in
[audio-proxy-api-v1.md](audio-proxy-api-v1.md) covers that. Read this when a
render produces something you did not expect, or before changing the argument
table.

`AudioProxy.Ffmpeg.Command.build/3` turns a validated options struct plus an
input URL into an argv list. It is a pure function and it is the last leg of
the round-trip: equal cache keys imply byte-identical commands, which is what
makes a cache hit a claim about bytes rather than about a URL.

```elixir
{:ok, opts} = AudioProxy.Options.parse("f:opus/br:96/t:12.5:30/fade:0.5:1")
AudioProxy.Ffmpeg.Command.build(opts, "https://masters.example/piece.wav",
                                type: :http)
# => ["-nostdin", "-hide_banner", "-loglevel", "error",
#     "-protocol_whitelist", "https,tls,tcp",
#     "-ss", "12.5", "-t", "30", "-i", "https://masters.example/piece.wav",
#     "-vn", "-sn", "-dn", "-af", "afade=t=in:st=0:d=0.5,afade=t=out:st=29:d=1",
#     "-c:a", "libopus", "-b:a", "96k", "-f", "ogg", "pipe:1"]
```

There is no shell anywhere in this path. The argv is a flat list of complete
arguments, so a source URL containing `;`, `$(…)` or spaces is one element and
stays data; `dl` and `cb` never reach the command at all.

The `type:` is the resolved source's own tag and it is required — see
[Audio only, at the argv](#audio-only-at-the-argv) for what it decides and why
there is no default.

## Option → ffmpeg mapping

| Option | ffmpeg | Notes |
|---|---|---|
| `t:START[:DUR]` | `-ss START [-t DUR]` **before** `-i` | Input seeking, so ffmpeg's HTTP client issues a Range request and never reads the skipped bytes. Everything downstream sees the trimmed region starting at t=0 |
| `fade:IN[:OUT]` | `afade=t=in:st=0:d=IN`, `afade=t=out:st=DUR-OUT:d=OUT` | Inside the trimmed region, by construction |
| `gain` | `volume=<dB>dB` | |
| `norm:ebu:I:TP:LRA` | `loudnorm=I=…:TP=…:LRA=…` | Single-pass (§3.2) |
| `sr` | `aresample=<Hz>` | |
| `ch` | `-ac 1` \| `-ac 2` | An output option, not a filter. Omitted, the render follows the source — except under `f:peaks`, which emits `-ac 1`; see below |
| `br` | `-b:a <kbps>k` | Lossy formats only |
| `q` | `-q:a` (mp3, ogg, aac, m4a) or `-compression_level` (opus, flac) | Whichever knob the codec has, bounded to its range |
| `bd` | `-c:a pcm_s16le`/`pcm_s24le`/`pcm_f32le` (wav), `-sample_fmt s16`/`s32` (flac) | Omitted, a lossless variant follows the source's depth |
| `f:mp3` | `-c:a libmp3lame -f mp3` | |
| `f:opus` | `-c:a libopus -f ogg` | |
| `f:ogg` | `-c:a libvorbis -f ogg` | |
| `f:aac` | `-c:a aac -f adts` | ADTS, because it streams |
| `f:m4a` | `-c:a aac -movflags empty_moov+default_base_moof -frag_duration 1000000 -f mp4` | Fragmented: plain MP4 needs a seekable output for its moov atom, and stdout is not one. Cut on duration, not `frag_keyframe` — see below |
| `f:flac` | `-c:a flac -f flac` | |
| `f:wav` | `-c:a pcm_s16le -f wav` | |
| `f:peaks` | `-c:a pcm_s16le -f s16le -ac 1` | Raw PCM for the peak reducer, not an encode. See below |

Every command writes to `pipe:1` behind an explicit `-f`, since stdout has no
filename for ffmpeg to infer a muxer from, and every command runs with
`-nostdin -hide_banner -loglevel error` so stderr carries diagnostics only.

## Audio only, at the argv

Two things appear in every argv regardless of the options, and neither comes
from the URL:

| Argument | Where | Why |
|---|---|---|
| `-vn -sn -dn` | after `-i`, so they bind the output | No video, subtitle or data stream is decoded, filtered or encoded, in any format and on the peaks PCM path too |
| `-protocol_whitelist <set>` | before `-i`, so it binds the input | ffmpeg may open only the protocols the resolved source actually needs |

The protocol set is a function of the source's *type*, never of the input
string and never of configuration:

| Source | Set | Reachable |
|---|---|---|
| `local://` | `file` | The filesystem only — no network protocol exists in this invocation |
| `https://` | `https,tls,tcp` | The network only — no `file`, so a redirect to `file:///etc/passwd` fails to open |
| `s3://` | `https,tls,tcp`, plus `http` when `AP_S3_ENDPOINT` is cleartext | As above; the presigned URL's scheme follows the endpoint |

The two sets are disjoint by construction, which is the property that makes
them worth having: a local render cannot fetch, a remote render cannot read
disk, and `concat:`, `subfile:`, `data:` and the rest are reachable from
neither. Because the set is derived from the source type, `build/3` requires
`type:` rather than defaulting it — a default would be a guess about which side
of that boundary a render sits on, and the wrong guess is a hole rather than a
crash. A source type with no entry in `protocols/1` raises for the same reason.

These are defence in depth, and one concrete case shows why they are not
redundant. The gate exempts cover art by trusting the `attached_pic`
disposition, which lives in the container — bytes the requester may control — so
a crafted file can wear it and pass. What that buys is bounded here rather than
there: with `-vn -sn -dn` the video stream is never mapped, so the render is an
audio-only encode of the audio track. The attacker gets audio extraction from a
video file, which is what the gate exists to refuse, and not a video transcode,
which is what would actually cost the operator. Layer one is the policy; layer
two is what makes forging layer one uninteresting.

The two layers are independent by construction, and one of them is a seam.
`AudioProxy.VideoPolicy` holds the *verdict* on a source `ffprobe` called
video, as a closed two-valued enum: `:reject`, which is the `415` above and the
default, or `:extract`, which admits the source and renders its audio track.
`AudioProxy.Ffprobe.has_video?/1` still answers the question identically under
either. What cannot move is the row in the table above: `Command.build/3` takes
the options, the input and the source type, and no policy is among its
arguments, so `-vn -sn -dn` is not conditional on a verdict it never sees and
the format vocabulary contains no video encoder to reach. An ingest policy can
change what is admitted; it has no argument through which to change what is
emitted. The knob is `Application.get_env(:audio_proxy, :video_policy)` and
deliberately not an `AP_` variable: the intended consumer is an embedding
release that owns its own application env, not an operator holding the
published image, which is why the configuration surface has no entry for it.

The gate that actually refuses a video source with `415` is an `ffprobe` run in
`AudioProxy.Plugs.RenderAction`, before the semaphore; the flags above are what
still holds if that gate is bypassed, reordered, or handed a source it cannot
see inside. Placement matters for both:
`-protocol_whitelist` after `-i` would bind the *output* format context and
protect nothing, and `-vn` before `-i` would be an input option ffmpeg reads
differently.

`Command.allowed_flags/0` publishes the complete flag vocabulary, and
`takes_value?/1` says which flags carry a value. The property suite walks a
generated argv position by position against both, so "no URL content can become
an ffmpeg flag" is a checked claim rather than a design intention. The walk is
necessary rather than decorative: ogg's quality scale starts at −1, so
`f:ogg/q:-1` renders `["-q:a", "-1"]` and a leading-hyphen check would have to
be loosened to tolerate it.

Two subprocesses read the source, not one, so both carry a whitelist. The
decode's is in the argv above; the probe's comes from `Ffprobe.args/2`, which
takes the protocol set as an argument rather than an option precisely because
`AudioProxy.Peaks.Render` builds its own probe argv (see below) and would
otherwise be the one route reading a source unrestricted.

## Why `f:peaks` runs ffmpeg twice, and why it is mono

Peaks are the one format where ffmpeg does not produce the response. It
decodes to raw interleaved `s16le` on stdout and `AudioProxy.Peaks` reduces
those samples to `pts` min/max pairs; the PCM is folded in chunk by chunk and
dropped, so a ten-minute source costs a few kilobytes of resident state rather
than the tens of megabytes it decodes to.

Streaming that reduction is what forces the **leading `ffprobe`**. Bucket
boundaries are `ceil(frames / pts)` and have to be known before the first
sample arrives; the alternative is buffering the whole decode and counting
afterwards, which trades a header read for memory proportional to the source.
So a peaks render is a probe and then a decode, both spawned through the same
render pipeline — same kill discipline, same `AP_RENDER_TIMEOUT`, same stderr
classification, which is why a 404 source fails a peaks request with the
status it would have failed an audio one with.

Probe and decode can disagree about the sample count by a frame or two, and
neither direction is reported: extra samples fold into the final bucket, and a
short decode leaves trailing pairs at `0, 0`. `length` is always the `pts` the
URL asked for.

The `-ac 1` is the other peaks-only rule. Every other format follows the
source when `ch` is absent; peaks downmix, because a waveform UI draws one
shape and following a stereo source would double the payload for a picture
nobody asked for. The reducer also has to know the interleaving before it
reads a byte, so "whatever the source had" is not an option the argv can leave
open. `ch:2` still gives per-channel pairs, and the mono default is
materialized into the cache key so `f:peaks` and `f:peaks/ch:1` are one
variant.

## Why `m4a` fragments on duration

`-movflags frag_keyframe` starts a new fragment at each video keyframe. An
audio-only stream has none, so `empty_moov` alone produces exactly **one**
fragment, which ffmpeg flushes when the input ends — a valid file on a
non-seekable pipe, but not a stream. Measured on a 20 s source fed at realtime:

| movflags | first bytes | fragments | size |
|---|---|---|---|
| `frag_keyframe+empty_moov` | 19.7 s | 1 | 328218 |
| `empty_moov+default_base_moof` + `-frag_duration 1000000` | 1.8 s | 20 | 327275 |
| `empty_moov+frag_every_frame` | 0.2 s | 863 | 437684 |
| mp3, for reference | 0.2 s | — | — |

One-second fragments cost nothing measurable in size and make the stream a
stream, so that is what the builder emits. The `:ffmpeg`-tagged suite counts
the fragments and measures time-to-first-byte, so the regression cannot come
back quietly.

Filters run in the order `loudnorm → volume → aresample → afade`, and the
order is load-bearing. `loudnorm` goes first because normalizing after a
static `gain` would undo it; `aresample` follows it because single-pass
`loudnorm` resamples its output to 192 kHz; `afade` goes last so the fade
shape survives the stages above it.

That 192 kHz has one visible consequence: **`norm` without an explicit `sr`
appends `aresample=48000`.** Without it every normalized render would be a
192 kHz file. 48 kHz is the API's own lossy ceiling (§3.1) and universally
supported, but it does mean `norm` on a 96 kHz lossless master downsamples.
Choosing better would need the source's real sample rate, which the argument
builder deliberately does not know — it is a pure function of the options, and
that purity is what the round-trip property rests on. Pass `sr` explicitly to
override.

## ffmpeg version

The argv is a contract with a specific ffmpeg, not with "ffmpeg" in the
abstract: encoder names, muxer names and filter option spellings all drift
between versions. The devcontainer and the release image therefore install
ffmpeg from the same distro packaging, and the `:ffmpeg`-tagged tests
(`test/audio_proxy/ffmpeg/command_ffmpeg_test.exs`) run every format and every
filter through the real binary, so a codec name that a build does not carry
fails a test rather than a request. Pinning an exact ffmpeg version — and
whether to build it from source with a trimmed codec set — is decided in
`add-docker-release`.

Two known gaps. libopus encodes at 48/24/16/12/8 kHz only, so `sr:44100` with
`f:opus` is resampled to 48 kHz by ffmpeg's own negotiation and produces the
same bytes as `f:opus` alone, under a different cache key. And with no `bd`,
`f:wav` falls back to 16-bit whenever the source's depth is unknown — the
builder takes it as an argument (`build/3`), but the probe that supplies it
belongs to the `/info` slice, so until then a 24-bit master requested as
`f:wav` comes back 16-bit unless `bd:24` is given. Both cost a duplicate cache
object or a documented fallback, not a wrong render, and both are tracked
alongside the semantic no-ops described under
[cache-key semantics](audio-proxy-api-v1.md#3-processing-options).
