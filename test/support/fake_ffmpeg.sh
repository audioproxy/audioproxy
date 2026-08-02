#!/bin/sh
# A stand-in for ffmpeg on the *HTTP* path, so the streaming lifecycle can be
# driven without the real encoder.
#
# `test/support/fake_cmd.sh` cannot do this job: it reads its directives from
# argv, and argv here is whatever AudioProxy.Ffmpeg.Command built. So this
# script takes its instructions from the one part of the argument vector a test
# controls end to end — the input path, which is the source in the signed URL.
# Name a fixture `hang.wav` and the render hangs; name it `dribble.wav` and it
# streams until it is killed.
#
#   hang.*      produce nothing, ever (until SIGTERM/SIGKILL arrives)
#   dribble.*   write a line every 100 ms, forever — a render whose next chunk
#               is always close, which is what disconnect detection needs
#   midfail.*   write two chunks, then exit 1 with an unclassifiable
#               diagnostic: the failure-after-200 case
#   notaudio.*  exit 1 with the diagnostic ffmpeg emits for an undecodable
#               input
#   failfast.*  exit 1 before any output, with a diagnostic no classifier
#               recognises: the unclassifiable failure before the first byte
#   presigned.* exit 1 with a diagnostic that quotes a presigned URL, query
#               string and all — the credential-leak case. Real ffmpeg is not
#               known to echo its input into its diagnostics; this is the
#               build that does, so the redaction guarantee is tested rather
#               than assumed.
#   anything    write the payload below and exit 0
#
# Matching is on the *basename*, anchored, and a substring match on the whole
# path would be a trap: ExUnit names its `tmp_dir` after the test, so a test
# whose name contains "change" would silently be a hang.
#
# Every write is a separate `printf`, hence a separate `write(2)`, so chunk
# boundaries are the script's and not the shell's buffering.

set -eu

PAYLOAD='fake-audio-payload'

input=""
prev=""
for arg in "$@"; do
  if [ "$prev" = "-i" ]; then
    input="$arg"
  fi
  prev="$arg"
done

case "${input##*/}" in
  hang.*)
    sleep 300
    ;;
  dribble.*)
    while :; do
      printf '%s\n' "$PAYLOAD"
      sleep 0.1
    done
    ;;
  midfail.*)
    printf '%s' "$PAYLOAD"
    sleep 0.1
    printf '%s' "$PAYLOAD"
    printf 'something went wrong in a way no classifier knows\n' >&2
    exit 1
    ;;
  notaudio.*)
    printf 'Invalid data found when processing input\n' >&2
    exit 1
    ;;
  failfast.*)
    printf 'something went wrong in a way no classifier knows\n' >&2
    exit 1
    ;;
  presigned.*)
    printf 'Error opening input file %s.\n' \
      'https://masters.s3.amazonaws.com/piece.wav?X-Amz-Algorithm=AWS4-HMAC-SHA256&X-Amz-Signature=deadbeefcafe' >&2
    exit 1
    ;;
  *)
    printf '%s' "$PAYLOAD"
    ;;
esac
