# How options become ffmpeg arguments

Implementation reference for `AudioProxy.Ffmpeg.Command`. Nothing here is
needed to *use* the proxy — the option grammar in the
[README](../README.md#processing-options) and
[audio-proxy-api-v1.md](audio-proxy-api-v1.md) cover that. Read this when a
render produces something you did not expect, or before changing the argument
table.

`AudioProxy.Ffmpeg.Command.build/3` turns a validated options struct plus an
input URL into an argv list. It is a pure function and it is the last leg of
the round-trip: equal cache keys imply byte-identical commands, which is what
makes a cache hit a claim about bytes rather than about a URL.

```elixir
{:ok, opts} = AudioProxy.Options.parse("f:opus/br:96/t:12.5:30/fade:0.5:1")
AudioProxy.Ffmpeg.Command.build(opts, "https://masters.example/piece.wav")
# => ["-nostdin", "-hide_banner", "-loglevel", "error",
#     "-ss", "12.5", "-t", "30", "-i", "https://masters.example/piece.wav",
#     "-vn", "-af", "afade=t=in:st=0:d=0.5,afade=t=out:st=29:d=1",
#     "-c:a", "libopus", "-b:a", "96k", "-f", "ogg", "pipe:1"]
```

There is no shell anywhere in this path. The argv is a flat list of complete
arguments, so a source URL containing `;`, `$(…)` or spaces is one element and
stays data; `dl` and `cb` never reach the command at all.

## Option → ffmpeg mapping

| Option | ffmpeg | Notes |
|---|---|---|
| `t:START[:DUR]` | `-ss START [-t DUR]` **before** `-i` | Input seeking, so ffmpeg's HTTP client issues a Range request and never reads the skipped bytes. Everything downstream sees the trimmed region starting at t=0 |
| `fade:IN[:OUT]` | `afade=t=in:st=0:d=IN`, `afade=t=out:st=DUR-OUT:d=OUT` | Inside the trimmed region, by construction |
| `gain` | `volume=<dB>dB` | |
| `norm:ebu:I:TP:LRA` | `loudnorm=I=…:TP=…:LRA=…` | Single-pass (§3.2) |
| `sr` | `aresample=<Hz>` | |
| `ch` | `-ac 1` \| `-ac 2` | An output option, not a filter |
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
| `f:peaks` | `-c:a pcm_s16le -f s16le` | Raw PCM for the peak reducer, not an encode |

Every command writes to `pipe:1` behind an explicit `-f`, since stdout has no
filename for ffmpeg to infer a muxer from, and every command runs with
`-nostdin -hide_banner -loglevel error` so stderr carries diagnostics only.

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
[cache-key semantics](../README.md#cache-key-semantics).
