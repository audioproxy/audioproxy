#!/bin/sh
# A stand-in for ffprobe on the *HTTP* path, so the info endpoint's response
# shape, caching and error mapping — and the render path's audio-only gate —
# can be driven without the real binary.
#
# Same trick as `fake_ffmpeg.sh`: argv is whatever AudioProxy.Ffprobe built, so
# the directive comes from the one part a test controls end to end — the input,
# which is the source in the signed URL. ffprobe takes its input positionally
# and this module puts it last, so the last argument is it.
#
#   unprobeable.* exit 1 with the diagnostic ffprobe emits for an input it
#                 cannot parse at all — the 415 case
#   silent.*      exit 0 with well-formed JSON that names no audio stream: a
#                 file ffprobe understood and this proxy still cannot serve
#   garbage.*     exit 0 writing something that is not JSON — the probe that
#                 "succeeded" and said nothing usable, which is a 500
#   probehang.*   produce nothing, ever, until the timeout kills it
#   probeslow.*   a half-second pause, then the default WAV — a probe slow
#                 enough for a burst to coalesce onto while it is still running
#   tagged.*      a lossy source carrying tags, no bit depth
#   video.*       audio plus a genuine h264 video stream — the gate's 415
#   videoonly.*   video and nothing else
#   cover.*       an mp3 with attached-picture cover art: not video
#   stillcover.*  the same cover art with no disposition data at all, only a
#                 single-frame image codec to go on — the ambiguous case
#   slideshow.*   a single-frame codec ffmpeg does not call a picture, with no
#                 disposition either: ambiguity that must fail closed
#   anything      a 48 kHz stereo 16-bit WAV
#
# Two directives are deliberately *absent*, because the render path now probes
# before it renders and a name that means something to both scripts would make
# a render test depend on the probe's behaviour: `hang.*` (fake_ffmpeg's own
# hang directive — hence `probehang.*` here) and `notaudio.*`, which falls
# through to the default so that a render test can still exercise a 415 the
# *encoder* diagnosed. A directive added here must not collide with one in
# fake_ffmpeg.sh.
#
# Matching is on the basename, anchored, for the reason fake_ffmpeg.sh gives.

set -eu

input=""
for arg in "$@"; do
  input="$arg"
done

case "${input##*/}" in
  unprobeable.*)
    printf 'Invalid data found when processing input\n' >&2
    exit 1
    ;;
  silent.*)
    cat <<'JSON'
{ "streams": [], "format": { "format_name": "mov,mp4,m4a,3gp,3g2,mj2", "duration": "12.0" } }
JSON
    ;;
  garbage.*)
    printf 'this is not json at all\n'
    ;;
  probehang.*)
    sleep 300
    ;;
  probeslow.*)
    # Long enough that a burst of requests is still arriving while this one runs,
    # so a coalescing test is about probes *in flight* rather than about a
    # verdict already held. Short enough not to be felt in the suite.
    sleep 0.5
    cat <<'JSON'
{
  "streams": [
    {
      "codec_type": "audio", "codec_name": "pcm_s16le", "sample_rate": "48000",
      "channels": 2, "bits_per_sample": 16
    }
  ],
  "format": { "format_name": "wav", "duration": "5.000000", "size": "960044" }
}
JSON
    ;;
  tagged.*)
    cat <<'JSON'
{
  "streams": [
    {
      "codec_type": "audio", "codec_name": "mp3", "sample_rate": "44100",
      "channels": 2, "bits_per_sample": 0, "bits_per_raw_sample": "N/A"
    }
  ],
  "format": {
    "format_name": "mp3", "duration": "182.464000", "size": "2921024",
    "bit_rate": "128000",
    "tags": { "title": "Sea Change", "artist": "Test Artist", "track": "3" }
  }
}
JSON
    ;;
  video.*)
    cat <<'JSON'
{
  "streams": [
    {
      "codec_type": "video", "codec_name": "h264", "nb_frames": "500",
      "disposition": { "attached_pic": 0 }
    },
    {
      "codec_type": "audio", "codec_name": "aac", "sample_rate": "48000",
      "channels": 2
    }
  ],
  "format": { "format_name": "mov,mp4,m4a,3gp,3g2,mj2", "duration": "20.0" }
}
JSON
    ;;
  videoonly.*)
    cat <<'JSON'
{
  "streams": [
    { "codec_type": "video", "codec_name": "h264", "nb_frames": "500" }
  ],
  "format": { "format_name": "mov,mp4,m4a,3gp,3g2,mj2", "duration": "20.0" }
}
JSON
    ;;
  cover.*)
    cat <<'JSON'
{
  "streams": [
    {
      "codec_type": "audio", "codec_name": "mp3", "sample_rate": "44100",
      "channels": 2
    },
    {
      "codec_type": "video", "codec_name": "mjpeg", "nb_frames": "1",
      "disposition": { "attached_pic": 1 }
    }
  ],
  "format": { "format_name": "mp3", "duration": "182.464000" }
}
JSON
    ;;
  stillcover.*)
    cat <<'JSON'
{
  "streams": [
    {
      "codec_type": "audio", "codec_name": "flac", "sample_rate": "44100",
      "channels": 2, "bits_per_raw_sample": 16
    },
    { "codec_type": "video", "codec_name": "png", "nb_frames": "1" }
  ],
  "format": { "format_name": "flac", "duration": "182.464000" }
}
JSON
    ;;
  slideshow.*)
    cat <<'JSON'
{
  "streams": [
    {
      "codec_type": "audio", "codec_name": "aac", "sample_rate": "48000",
      "channels": 2
    },
    { "codec_type": "video", "codec_name": "hevc", "nb_frames": "1" }
  ],
  "format": { "format_name": "mov,mp4,m4a,3gp,3g2,mj2", "duration": "20.0" }
}
JSON
    ;;
  *)
    cat <<'JSON'
{
  "streams": [
    {
      "codec_type": "audio", "codec_name": "pcm_s16le", "sample_rate": "48000",
      "channels": 2, "bits_per_sample": 16
    }
  ],
  "format": {
    "format_name": "wav", "duration": "5.000000", "size": "960044",
    "bit_rate": "1536000"
  }
}
JSON
    ;;
esac
