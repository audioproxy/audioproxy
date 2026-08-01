#!/bin/sh
# A stand-in for ffmpeg, so the render lifecycle can be tested without it.
#
# Every path AudioProxy.Ffmpeg.Render has to survive — a long output stream, a
# hang, a nonzero exit with diagnostics on stderr, a process that refuses
# SIGTERM — is a property of the subprocess, not of ffmpeg. Driving them with
# the real encoder would mean tests that are slow, that depend on a binary this
# repo does not ship, and that cannot produce a refusal to die on demand.
#
# Directives are read from argv and run in order, so one invocation composes a
# whole scenario:
#
#   fake_cmd.sh emit 4096 stderr "Invalid data found when processing input" exit 1
#   fake_cmd.sh ignore-term sleep 30
#
#   emit N       write N bytes of the deterministic pattern below to stdout
#   stderr TEXT  write TEXT, plus a newline, to stderr
#   sleep S      sleep S seconds
#   exit K       exit with status K (stops reading directives)
#   ignore-term  ignore SIGTERM and SIGINT from here on; only SIGKILL ends this
#   args         write every remaining argument to stdout, one per line, and
#                exit 0 — proves argv arrived verbatim, with no shell in between
#
# With no `exit` directive the script exits 0 once the list is exhausted.
#
# The `emit` pattern is the 62-character alphanumeric block below followed by a
# newline, repeated and truncated to N bytes — a 63-byte period, so a chunk
# boundary in the wrong place or two chunks in the wrong order changes the
# bytes. AudioProxy.Ffmpeg.RenderTest builds the same string to compare against.

set -eu

BLOCK='0123456789abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ'

while [ "$#" -gt 0 ]; do
  case "$1" in
    emit)
      # `yes` repeats the block indefinitely (one newline per line, hence the
      # 63-byte period) and `head -c` cuts it to size; the SIGPIPE that closes
      # `yes` is expected, so it must not fail the script under `set -e`.
      # `yes` is closed by SIGPIPE when `head` has taken its fill, which is
      # both expected and noisy — hence the discarded stderr and the `|| true`
      # that keeps `set -e` out of it.
      { yes "$BLOCK" 2>/dev/null || true; } | head -c "$2"
      shift 2
      ;;
    stderr)
      printf '%s\n' "$2" >&2
      shift 2
      ;;
    sleep)
      sleep "$2"
      shift 2
      ;;
    exit)
      exit "$2"
      ;;
    ignore-term)
      trap '' TERM INT
      shift
      ;;
    args)
      shift
      for arg in "$@"; do
        printf '%s\n' "$arg"
      done
      exit 0
      ;;
    *)
      printf 'fake_cmd.sh: unknown directive %s\n' "$1" >&2
      exit 64
      ;;
  esac
done

exit 0
