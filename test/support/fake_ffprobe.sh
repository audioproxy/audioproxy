#!/bin/sh
# A stand-in for ffprobe on the *HTTP* path, so the info endpoint's response
# shape, caching and error mapping can be driven without the real binary.
#
# Same trick as `fake_ffmpeg.sh`: argv is whatever AudioProxy.Ffprobe built, so
# the directive comes from the one part a test controls end to end — the input,
# which is the source in the signed URL. ffprobe takes its input positionally
# and this module puts it last, so the last argument is it.
#
#   notaudio.*  exit 1 with the diagnostic ffprobe emits for an input it
#               cannot parse at all — the 415 case
#   silent.*    exit 0 with well-formed JSON that names no audio stream: a
#               file ffprobe understood and this proxy still cannot serve
#   garbage.*   exit 0 writing something that is not JSON — the probe that
#               "succeeded" and said nothing usable, which is a 500
#   hang.*      produce nothing, ever, until the timeout kills it
#   tagged.*    a lossy source carrying tags, no bit depth
#   anything    a 48 kHz stereo 16-bit WAV
#
# Matching is on the basename, anchored, for the reason fake_ffmpeg.sh gives.

set -eu

input=""
for arg in "$@"; do
  input="$arg"
done

case "${input##*/}" in
  notaudio.*)
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
  hang.*)
    sleep 300
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
